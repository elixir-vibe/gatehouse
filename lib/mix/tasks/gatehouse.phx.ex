defmodule Mix.Tasks.Gatehouse.Phx do
  @moduledoc """
  Starts `mix phx.server` behind a local Gatehouse HTTPS proxy.

      mix gatehouse.phx
      mix gatehouse.phx --open
      mix gatehouse.phx --host my-app.localhost

  This is a Phoenix-focused shortcut for:

      mix gatehouse.run -- mix phx.server
  """

  use Mix.Task

  @shortdoc "Start Phoenix behind a local Gatehouse HTTPS proxy"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("gatehouse.run", args ++ ["--", "mix", "phx.server"])
  end
end
