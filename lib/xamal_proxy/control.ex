defmodule XamalProxy.Control do
  @moduledoc """
  Control-plane API for local or distributed Xamal deployers.

  A local caller can invoke these functions directly. A remote deployer can use
  Erlang distribution:

      :rpc.call(:"xamal_proxy@host", XamalProxy.Control, :deploy, [spec], 60_000)
  """

  alias XamalProxy.Config
  alias XamalProxy.Config.Service, as: ConfigService
  alias XamalProxy.Service
  alias XamalProxy.Service.State
  alias XamalProxy.Store
  alias XamalProxy.Telemetry

  @type deploy_spec :: Service.deploy_spec()

  @spec deploy(deploy_spec()) :: {:ok, State.t()} | {:error, term()}
  def deploy(%{service: service} = spec) when is_binary(service) do
    start = System.monotonic_time()

    result =
      with {:ok, _pid} <- ensure_service(service),
           {:ok, state} <- Service.deploy(service, spec),
           :ok <- persist_if_configured() do
        {:ok, state}
      end

    Telemetry.execute([:deploy, :stop], %{duration: System.monotonic_time() - start}, %{
      service: service,
      result: telemetry_result(result)
    })

    result
  end

  @spec get_service(String.t()) :: {:ok, State.t()} | {:error, :not_found}
  def get_service(service) when is_binary(service) do
    case Registry.lookup(XamalProxy.ServiceRegistry, service) do
      [{_pid, _value}] -> {:ok, Service.get(service)}
      [] -> {:error, :not_found}
    end
  end

  @spec routes() :: [{String.t(), String.t(), String.t()}]
  def routes do
    XamalProxy.RouteTable.all()
  end

  @spec checkout(String.t(), String.t()) :: {:ok, XamalProxy.Target.t()} | {:error, term()}
  def checkout(service, target_id) do
    Service.checkout(service, target_id)
  end

  @spec checkin(String.t(), String.t()) :: :ok
  def checkin(service, target_id) do
    Service.checkin(service, target_id)
  end

  @spec apply_config(Config.t()) :: :ok | {:error, term()}
  def apply_config(%Config{} = config) do
    Enum.reduce_while(config.services, :ok, fn service, :ok ->
      case deploy_config_service(service) do
        {:ok, _state} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {service.name, reason}}}
      end
    end)
  end

  @spec snapshot() :: %{services: [State.t()], routes: [{String.t(), String.t(), String.t()}]}
  def snapshot do
    services =
      XamalProxy.ServiceRegistry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.sort()
      |> Enum.map(&Service.get/1)

    %{services: services, routes: routes()}
  end

  @spec save(Path.t()) :: :ok | {:error, term()}
  def save(path) when is_binary(path) do
    Store.save(path, snapshot())
  end

  @spec restore(Path.t()) :: :ok | {:error, term()}
  def restore(path) when is_binary(path) do
    with {:ok, %{services: services}} <- Store.load(path) do
      Enum.each(services, &restore_service/1)
      :ok
    end
  end

  @spec restore_if_configured() :: :ok | {:error, term()}
  def restore_if_configured do
    case persistence_path() do
      nil -> :ok
      path -> restore(path)
    end
  end

  defp deploy_config_service(%ConfigService{} = service) do
    case ConfigService.active_target(service) do
      nil ->
        ensure_service(service.name)

      target ->
        deploy(%{
          service: service.name,
          hosts: service.hosts,
          target_id: target.name,
          target_url: target.url,
          health_path: service.health.path,
          health_timeout: service.health.timeout,
          drain_timeout: service.drain.timeout,
          metadata: target.metadata,
          skip_health_check: true
        })
    end
  end

  defp restore_service(%State{id: id, hosts: hosts, active_target: target})
       when not is_nil(target) do
    spec = %{
      service: id,
      hosts: hosts,
      target_id: target.id,
      target_url: URI.to_string(target.url),
      metadata: target.metadata,
      skip_health_check: true
    }

    {:ok, _state} = deploy(spec)
  end

  defp restore_service(%State{id: id}) do
    {:ok, _pid} = ensure_service(id)
  end

  defp persist_if_configured do
    case persistence_path() do
      nil -> :ok
      path -> save(path)
    end
  end

  defp telemetry_result({:ok, _state}), do: :ok
  defp telemetry_result({:error, reason}), do: {:error, reason}

  defp persistence_path do
    Application.get_env(:xamal_proxy, :persistence_path)
  end

  defp ensure_service(service) do
    case Registry.lookup(XamalProxy.ServiceRegistry, service) do
      [{pid, _value}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(XamalProxy.ServiceSupervisor, {Service, service})
    end
  end
end
