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
- `XamalProxy.Listener` and `XamalProxy.ReverseProxy` provide a minimal,
  replaceable HTTP/1.1 proxy prototype.

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

Set `:http_port` to start the prototype TCP listener:

```elixir
config :xamal_proxy, http_port: 8080
```

Set `:persistence_path` to restore saved service state on boot and persist after
deploys:

```elixir
config :xamal_proxy, persistence_path: "/var/lib/xamal-proxy/state.etf"
```

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

1. Replace the prototype listener/proxy with the final Livery + Gun/Mint runtime.
2. Add streaming request/response bodies and WebSocket support.
3. Add first-class release/CLI scripts for safe distribution startup.
4. Add operational telemetry and drain observability.
5. Keep ACME as a separate supervised subsystem after routing is solid.
