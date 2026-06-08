defmodule DemoApp.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    port =
      "PORT"
      |> System.get_env("4000")
      |> String.to_integer()

    children = [
      {DemoApp.Server, port: port, label: System.get_env("LABEL", "demo")}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DemoApp.Supervisor)
  end
end
