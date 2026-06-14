defmodule Gatehouse.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Gatehouse.RouteTable,
      Gatehouse.ACME.ChallengeStore,
      Gatehouse.ACME.RenewalScheduler,
      Gatehouse.Backend.ConnectionPool,
      {DynamicSupervisor, strategy: :one_for_one, name: Gatehouse.SafeRPC.PoolSupervisor},
      Gatehouse.SafeRPC.Pool,
      {Registry, keys: :unique, name: Gatehouse.ServiceRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Gatehouse.ServiceSupervisor},
      {Task.Supervisor, name: Gatehouse.RequestSupervisor},
      Gatehouse.Restorer,
      Gatehouse.LiveryListener
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Gatehouse.Supervisor)
  end
end
