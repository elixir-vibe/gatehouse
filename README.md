# XamalProxy

OTP-native edge proxy and blue-green traffic switcher for Xamal deployments.

This package is the beginning of a BEAM-native replacement for the current
Caddy reload step in Xamal. The proxy should run as a stable Erlang node at the
edge while Xamal orchestrates releases over SSH.

## First architecture slice

The initial package is intentionally small and OTP-first:

- `XamalProxy.Application` starts the supervision tree.
- `XamalProxy.RouteTable` owns a named ETS table for fast host lookups.
- `XamalProxy.Service` owns deploy/switch/drain state for one logical service.
- `XamalProxy.Control` is the distribution-friendly control API.
- `XamalProxy.Target` models one backend target.
- `XamalProxy.HealthCheck` provides a minimal health-check helper.
- `XamalProxy.Store` provides atomic ETF persistence helpers.

A remote Xamal deployer can eventually call the edge node through Erlang
distribution:

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
  metadata: %{version: "20260608-1"}
}
```

## Development

This project was created with Igniter and VibeKit:

```sh
mix igniter.new xamal_proxy --sup --install vibe_kit --yes
```

Run the fast checks with:

```sh
mix test
mix ci
```

## Near-term roadmap

1. Promote `XamalProxy.Service` to `:gen_statem` once health-check and drain
   transitions are implemented.
2. Add listener/reverse-proxy runtime, likely via Livery plus Gun or Mint.
3. Add real deploy command semantics: health check before activation, drain old
   targets, stop/rollback decisions.
4. Persist and restore service state on boot.
5. Add a local CLI for safe `:rpc` calls over SSH/local distribution.
6. Keep ACME as a separate supervised subsystem after routing is solid.
