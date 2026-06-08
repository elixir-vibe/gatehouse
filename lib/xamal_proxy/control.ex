defmodule XamalProxy.Control do
  @moduledoc """
  Control-plane API for local or distributed Xamal deployers.

  A local caller can invoke these functions directly. A remote deployer can use
  Erlang distribution:

      :rpc.call(:"xamal_proxy@host", XamalProxy.Control, :deploy, [spec], 60_000)
  """

  alias XamalProxy.Service

  @type deploy_spec :: Service.deploy_spec()

  @spec deploy(deploy_spec()) :: {:ok, XamalProxy.Service.State.t()} | {:error, term()}
  def deploy(%{service: service} = spec) when is_binary(service) do
    with {:ok, _pid} <- ensure_service(service) do
      Service.deploy(service, spec)
    end
  end

  @spec get_service(String.t()) :: {:ok, XamalProxy.Service.State.t()} | {:error, :not_found}
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

  defp ensure_service(service) do
    case Registry.lookup(XamalProxy.ServiceRegistry, service) do
      [{pid, _value}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(XamalProxy.ServiceSupervisor, {Service, service})
    end
  end
end
