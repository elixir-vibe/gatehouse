defmodule XamalProxy.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dmkenney/xamal_proxy"

  def project do
    [
      app: :xamal_proxy,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: description(),
      source_url: @source_url,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "_build/dev/dialyxir_plt.plt"},
        plt_add_apps: [:mix]
      ],
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {XamalProxy.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp description do
    "OTP-native edge proxy and blue-green traffic switcher for Xamal deployments."
  end

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
