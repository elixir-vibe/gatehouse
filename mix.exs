defmodule Gatehouse.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elixir-vibe/gatehouse"

  def project do
    [
      app: :gatehouse,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: description(),
      source_url: @source_url,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_file: {:no_warn, "_build/dev/dialyxir_plt.plt"},
        plt_add_apps: [:mix]
      ],
      package: package(),
      docs: docs(),
      releases: releases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "playground/demo_app/lib"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :telemetry, :gun, :livery],
      mod: {Gatehouse.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp description do
    "OTP-native edge proxy and blue-green traffic switcher for Elixir deployments."
  end

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "== 0.1.2", only: [:dev, :test], runtime: false, override: true},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Temporary fork until Livery publishes ssl_opts forwarding, HTTP/2 authority
      # propagation, and HTTPS H1 WebSocket upgrades.
      {:livery,
       git: "https://github.com/dannote/livery.git",
       ref: "f62037300a3d45ca31b9b93497ebe3dea65514d8"},
      {:ex_acme, "~> 0.7"},
      {:x509, "~> 0.9"},
      {:muontrap, "~> 1.8"},
      {:gun, "~> 2.4"},
      {:telemetry, "~> 1.3"},
      {:req, "~> 0.5.8"},
      {:safe_rpc, "~> 0.1"},
      {:plug, "~> 1.18"},
      {:systemdkit, "~> 0.1.2"}
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

  defp releases do
    [
      gatehouse: [
        include_executables_for: [:unix],
        applications: [gatehouse: :permanent]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib docs rel config .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "docs/phoenix-dev.md",
        "docs/systemd.md",
        "docs/erlang-distribution.md",
        "docs/telemetry.md",
        "docs/load-testing.md"
      ],
      groups_for_extras: [Guides: ~r/docs\//],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
