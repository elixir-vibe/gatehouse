defmodule DemoApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo_app,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :livery],
      mod: {DemoApp.Application, []}
    ]
  end

  defp deps do
    [
      {:livery, git: "https://github.com/benoitc/livery.git", branch: "main"}
    ]
  end
end
