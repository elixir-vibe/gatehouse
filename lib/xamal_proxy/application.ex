defmodule XamalProxy.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      XamalProxy.RouteTable,
      XamalProxy.ACME.ChallengeStore,
      XamalProxy.ACME.RenewalScheduler,
      XamalProxy.Backend.ConnectionPool,
      XamalProxy.SafeRPC.Pool,
      {Registry, keys: :unique, name: XamalProxy.ServiceRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: XamalProxy.ServiceSupervisor},
      {Task.Supervisor, name: XamalProxy.RequestSupervisor},
      XamalProxy.Restorer,
      XamalProxy.LiveryListener
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: XamalProxy.Supervisor)
  end
end
