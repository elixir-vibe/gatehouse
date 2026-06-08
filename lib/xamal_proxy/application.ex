defmodule XamalProxy.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      XamalProxy.RouteTable,
      {Registry, keys: :unique, name: XamalProxy.ServiceRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: XamalProxy.ServiceSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: XamalProxy.Supervisor)
  end
end
