defmodule XamalProxy.ConfigTest do
  use ExUnit.Case, async: true

  alias XamalProxy.Config

  test "parses minimal Caddy-like top-level directives" do
    config =
      Config.eval!("""
      import XamalProxy.Config

      state "/var/lib/xamal-proxy/state.etf"
      acme provider: XamalProxy.Acme.Provider, email: "ops@example.com"
      http port: 80
      https port: 443

      service :my_app do
        host "Example.COM"
        host "www.example.com"

        target :blue, "http://127.0.0.1:4000", active: true
        target :green, "http://127.0.0.1:4001"

        health "/up", timeout: 5_000, interval: 1_000
        drain 30_000
        tls :auto
      end
      """)

    assert config.state_path == "/var/lib/xamal-proxy/state.etf"
    assert config.acme[:email] == "ops@example.com"
    assert Enum.map(config.listeners, & &1.scheme) == [:http, :https]

    assert [service] = config.services
    assert service.name == "my_app"
    assert service.hosts == ["example.com", "www.example.com"]
    assert service.health == %{path: "/up", timeout: 5_000, interval: 1_000}
    assert service.drain == %{timeout: 30_000}
    assert service.tls == :auto

    assert Config.Service.active_target(service).name == "blue"
  end

  test "applies active static targets to the runtime control plane" do
    config =
      Config.eval!("""
      import XamalProxy.Config

      service :configured do
        host "configured.example.com"
        target :blue, "http://127.0.0.1:4000", active: true
      end
      """)

    assert :ok = XamalProxy.Control.apply_config(config)
    assert {:ok, "configured", "blue"} = XamalProxy.RouteTable.lookup("configured.example.com")
  end
end
