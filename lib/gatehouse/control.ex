defmodule Gatehouse.Control do
  @moduledoc """
  Control-plane API for local or distributed Elixir deployers.

  A local caller can invoke these functions directly. A remote deployer can use
  Erlang distribution:

      :rpc.call(:"gatehouse@host", Gatehouse.Control, :deploy, [spec], 60_000)
  """

  alias Gatehouse.Config
  alias Gatehouse.Config.Service, as: ConfigService
  alias Gatehouse.HealthCheck
  alias Gatehouse.Service
  alias Gatehouse.Service.State
  alias Gatehouse.Store
  alias Gatehouse.Telemetry

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
    case Registry.lookup(Gatehouse.ServiceRegistry, service) do
      [{_pid, _value}] -> {:ok, Service.get(service)}
      [] -> {:error, :not_found}
    end
  end

  @spec routes() :: [{String.t(), String.t(), String.t()}]
  def routes do
    Gatehouse.RouteTable.all()
  end

  @spec checkout(String.t(), String.t() | :select) ::
          {:ok, Gatehouse.Target.t()} | {:error, term()}
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
      Gatehouse.ServiceRegistry
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

  defp deploy_config_service(%ConfigService{balance: %{policy: :round_robin}} = service) do
    with {:ok, targets} <- balanced_targets(service),
         {:ok, _pid} <- ensure_service(service.name) do
      Service.configure(service.name, %{
        hosts: service.hosts,
        balance: :round_robin,
        targets: Enum.map(targets, &target_spec/1)
      })
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
          metadata: target_metadata(target),
          skip_health_check: true
        })
    end
  end

  defp target_spec(target),
    do: %{id: target.name, url: target.url, metadata: target_metadata(target)}

  defp target_metadata(target) do
    target.metadata
    |> Map.put(:kind, target.kind)
    |> Map.put(:socket, target.socket)
    |> Map.put(:op, target.op)
    |> Map.put(:shards, target.shards)
  end

  defp balanced_targets(%ConfigService{} = service) do
    targets = active_or_all_targets(service)

    if service.balance.options[:health] == :required do
      healthy_targets(service, targets)
    else
      {:ok, targets}
    end
  end

  defp active_or_all_targets(%ConfigService{targets: targets}) do
    case Enum.filter(targets, & &1.active?) do
      [] -> targets
      active_targets -> active_targets
    end
  end

  defp healthy_targets(service, targets) do
    healthy =
      Enum.filter(targets, fn
        %{kind: :safe_rpc} ->
          true

        target ->
          case URI.new(target.url) do
            {:ok, uri} ->
              HealthCheck.check(uri, path: service.health.path, timeout: service.health.timeout) ==
                :ok

            {:error, _reason} ->
              false
          end
      end)

    case healthy do
      [] -> {:error, :no_healthy_targets}
      targets -> {:ok, targets}
    end
  end

  defp restore_service(%State{id: id, hosts: hosts, active_target: target})
       when not is_nil(target) do
    spec = %{
      service: id,
      hosts: hosts,
      target_id: target.id,
      target_url: target_url(target),
      metadata: target.metadata,
      skip_health_check: true
    }

    {:ok, _state} = deploy(spec)
  end

  defp restore_service(%State{id: id}) do
    {:ok, _pid} = ensure_service(id)
  end

  defp target_url(%{url: nil}), do: nil
  defp target_url(%{url: url}), do: URI.to_string(url)

  defp persist_if_configured do
    case persistence_path() do
      nil -> :ok
      path -> save(path)
    end
  end

  defp telemetry_result({:ok, _state}), do: :ok
  defp telemetry_result({:error, reason}), do: {:error, reason}

  defp persistence_path do
    Application.get_env(:gatehouse, :persistence_path)
  end

  defp ensure_service(service) do
    case Registry.lookup(Gatehouse.ServiceRegistry, service) do
      [{pid, _value}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(Gatehouse.ServiceSupervisor, {Service, service})
    end
  end
end
