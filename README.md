# XamalProxy

OTP-native edge proxy and blue-green traffic switcher for Xamal deployments.

This package is the beginning of a BEAM-native replacement for the current
Caddy reload step in Xamal. The proxy should run as a stable Erlang node at the
edge while Xamal orchestrates releases over SSH.

## Current architecture slice

The package is intentionally small and OTP-first:

- `XamalProxy.Application` starts the supervision tree.
- `XamalProxy.RouteTable` owns a named ETS table for fast host lookups.
- `XamalProxy.Service` is a `:gen_statem` process per logical service.
- `XamalProxy.Control` is the distribution-friendly control API.
- `XamalProxy.Target` models one backend target and request counts.
- `XamalProxy.HealthCheck` validates targets before activation.
- `XamalProxy.Store` provides atomic ETF persistence helpers.
- `XamalProxy.LiveryListener` provides Livery-based HTTP ingress.
- `XamalProxy.Backend.Gun` performs pooled backend requests and streams request/response bodies through Gun.
- `XamalProxy.WebSocketProxy` bridges Livery WebSocket upgrades to backend Gun WebSocket sessions.
- `XamalProxy.ACME.Provider` defines the ACME adapter boundary.
- `XamalProxy.ACME.RenewalScheduler` persists renewed certs and asks the listener to refresh TLS.

A remote Xamal deployer can call the edge node through Erlang distribution:

```elixir
:rpc.call(:"xamal_proxy@host", XamalProxy.Control, :deploy, [spec], 60_000)
```

Example deploy spec:

```elixir
%{
  service: "my_app",
  hosts: ["example.com"],
  target_id: "green-20260608-1",
  target_url: "http://127.0.0.1:4001",
  health_path: "/up",
  health_timeout: 5_000,
  drain_timeout: 30_000,
  metadata: %{version: "20260608-1"}
}
```

## Runtime configuration

Use a minimal Caddy-like Elixir DSL. There is no root wrapper:

```elixir
import XamalProxy.Config

state "/var/lib/xamal-proxy/state.etf"
http port: 80
https port: 443, cert: "/etc/xamal-proxy/certs/example.crt", key: "/etc/xamal-proxy/certs/example.key"

service :my_app do
  host "example.com"
  host "www.example.com"

  target :blue, "http://127.0.0.1:4000", active: true
  target :green, "http://127.0.0.1:4001"

  balance :round_robin
  health "/up", timeout: 5_000, interval: 1_000
  drain 30_000
  tls :auto
end
```

Point the release at that file with ordinary application config:

```elixir
config :xamal_proxy, config_path: "/etc/xamal-proxy.exs"
```

Set `:livery_http_port` to start the Livery HTTP listener:

```elixir
config :xamal_proxy, livery_http_port: 8080
```

HTTPS listener cert/key paths are retained; `XamalProxy.LiveryListener.refresh_tls/1` rereads them and restarts the Livery service. Successful ACME renewals call this automatically.

Set `:persistence_path` to restore saved service state on boot and persist after
deploys:

```elixir
config :xamal_proxy, persistence_path: "/var/lib/xamal-proxy/state.etf"
```

## ACME

`XamalProxy.ACME.Provider.ExAcme` is the primary Elixir ACME adapter. It uses
`ex_acme` for account registration, HTTP-01 authorization, CSR finalization,
certificate fetch, and revocation. HTTP-01 tokens are published through
`XamalProxy.ACME.ChallengeStore`, which the Livery handler serves before proxy
routing.

The older `XamalProxy.ACME.Provider.AcmeClient` adapter remains as an optional
boundary for the Erlang `acme_client` package, but it is not the default path.

Pebble integration coverage is opt-in because it needs Docker or a separately
running Pebble server:

```sh
XAMAL_PROXY_PEBBLE=1 mix test test/xamal_proxy/acme_pebble_integration_test.exs
```

The test starts `ghcr.io/letsencrypt/pebble:latest` with
`PEBBLE_VA_ALWAYS_VALID=1` unless `XAMAL_PROXY_PEBBLE_EXTERNAL=1` is set.

## Development

This project was created with Igniter and VibeKit:

```sh
mix igniter.new xamal_proxy --sup --install vibe_kit --yes
```

Run checks with:

```sh
mix ci
```

## Near-term roadmap

1. Add richer telemetry dashboards/examples.
2. Add TLS listener wiring and certificate store.
3. Implement a real ACME provider adapter behind `XamalProxy.ACME.Provider`.
4. Add load-balancing policies beyond one active target.
5. Add full multi-target runtime load balancing beyond the config shape.
