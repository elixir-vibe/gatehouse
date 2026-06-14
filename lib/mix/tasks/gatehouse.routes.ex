defmodule Mix.Tasks.Gatehouse.Routes do
  @moduledoc """
  Prints routes currently registered in the local Gatehouse node.
  """

  use Mix.Task

  @shortdoc "Print local Gatehouse routes"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:gatehouse)

    routes = Gatehouse.Control.routes()

    if routes == [] do
      Mix.shell().info("No Gatehouse routes are registered.")
    else
      Enum.each(routes, fn {host, service, target} ->
        Mix.shell().info("#{host} -> #{service} / #{target}")
      end)
    end
  end
end
