# Gatehouse

OTP-native edge proxy and blue-green traffic switcher for Elixir deployments.

> [!NOTE]
> The `gatehouse` package currently published on Hex as `0.0.1` is a placeholder
> that reserves the package name. Use this repository as the canonical source
> while the first usable Gatehouse release is prepared.

Gatehouse is a BEAM-native application router for HostKit-style deployments.
The proxy runs as a stable Erlang node at the edge while deploy tooling
orchestrates releases over SSH.

## Package status

The public Hex package is intentionally a placeholder for now:

- `gatehouse 0.0.1` reserves the package name and is not a usable runtime.
- The real Gatehouse code currently lives in this public repository.
- HostKit source deployments should clone this repository directly until the
  first usable Gatehouse package is released.
- The real Hex release is blocked on upstream Livery dependency resolution:
  Hex `livery 0.3.2` is currently unsatisfiable because it depends on
  `barrel_mcp ~> 2.2.3`, which pins `hackney 4.3.0`, while Livery itself
  requires `hackney ~> 4.4.0`.
- Gatehouse temporarily depends on a Livery Git fork while upstream PRs for
  dependency resolution and transport fixes are pending.

Use a Git dependency while this status remains:

```elixir
{:gatehouse, github: "elixir-vibe/gatehouse", branch: "master"}
```

## Current architecture slice

The package is intentionally small and OTP-first:

- `Gatehouse.Application` starts the supervision tree.
- `Gatehouse.RouteTable` owns a named ETS table for fast host lookups.
- `Gatehouse.Service` is a `:gen_statem` process per logical service.
- `Gatehouse.Control` is the distribution-friendly control API.
- `Gatehouse.Target` models one backend target and request counts.
- `Gatehouse.HealthCheck` validates targets before activation.
- `Gatehouse.Store` provides atomic ETF persistence helpers.
- `Gatehouse.LiveryListener` provides Livery-based HTTP ingress.
- `Gatehouse.Backend.Gun` performs pooled backend requests and streams request/response bodies through Gun.
- `Gatehouse.WebSocketProxy` bridges Livery WebSocket upgrades to backend Gun WebSocket sessions.
- `Gatehouse.ACME.Provider` defines the ACME adapter boundary.
- `Gatehouse.ACME.RenewalScheduler` persists renewed certs and asks the listener to refresh TLS.

A remote deployer can call the edge node through Erlang distribution:

```elixir
:rpc.call(:"gatehouse@host", Gatehouse.Control, :deploy, [spec], 60_000)
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
import Gatehouse.Config

state "/var/lib/gatehouse/state.etf"
http port: 80
https port: 443,
  cert: "/etc/gatehouse/certs/fallback.crt",
  key: "/etc/gatehouse/certs/fallback.key"

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
config :gatehouse, config_path: "/etc/gatehouse.exs"
```

HTTPS listener cert/key paths are retained; `Gatehouse.LiveryListener.refresh_tls/1` rereads them and restarts the Livery service. Successful ACME renewals call this automatically. When `acme` is configured and any service uses `tls :auto`, the HTTPS listener automatically installs an Erlang/OTP `:ssl` SNI callback backed by the ACME certificate store.

Set `:persistence_path` to restore saved service state on boot and persist after
deploys:

```elixir
config :gatehouse, persistence_path: "/var/lib/gatehouse/state.etf"
```

## ACME

`Gatehouse.ACME.Provider.ExAcme` is the primary Elixir ACME adapter. It uses
`ex_acme` for account registration, HTTP-01 authorization, CSR finalization,
certificate fetch, and revocation. HTTP-01 tokens are published through
`Gatehouse.ACME.ChallengeStore`, which the Livery handler serves before proxy
routing.

Static config now turns `tls :auto` services into renewal jobs automatically:

```elixir
acme email: "ops@example.com",
  cert_directory: "/var/lib/gatehouse/certs",
  account_directory: "/var/lib/gatehouse/acme"

service :my_app do
  host "example.com"
  host "www.example.com"
  tls :auto
end
```

The generated job stores certificates under `cert_directory`, writes aliases for
all service hosts, and persists the ACME account key under `account_directory` so
renewals reuse the same account. SNI lookup uses the same certificate store, so a
certificate issued for `example.com` and `www.example.com` can be selected by
either hostname.

Pebble integration coverage is opt-in because it needs a local Pebble server:

```sh
scripts/pebble_integration_test.sh
```

Like `systemdkit`, the script copies the project into the Lima VM named
`systemd-test`, builds Pebble from source with Go if needed, starts Pebble with
`PEBBLE_VA_ALWAYS_VALID=1`, and runs:

```sh
GATEHOUSE_PEBBLE=1 GATEHOUSE_PEBBLE_EXTERNAL=1 mix test test/gatehouse/acme_pebble_integration_test.exs
```

## Phoenix local HTTPS DX

Phoenix apps can add Gatehouse as a dev dependency and run their dev server
behind a stable local HTTPS URL. Until the first usable Hex package is released,
use the public Git repository:

```elixir
# mix.exs in your Phoenix app
def deps do
  [
    {:gatehouse, github: "elixir-vibe/gatehouse", branch: "master", only: :dev, runtime: false}
  ]
end
```

```sh
mix gatehouse.trust
mix gatehouse.phx
# => https://my-app.localhost:4443 -> http://127.0.0.1:<random-port>
```

`mix gatehouse.phx` chooses a free backend port, exposes it as `PORT`, starts a
local Gatehouse HTTPS proxy, registers the `.localhost` host, and then runs
`mix phx.server`. Regular Phoenix requests, static assets, and LiveView
WebSockets are proxied through the same HTTPS origin. For custom commands use:

```sh
mix gatehouse.run -- mix phx.server
mix gatehouse.run --open -- mix phx.server
mix gatehouse.run --host admin.localhost --proxy-port 443 -- mix phx.server
mix gatehouse.run --no-tls -- mix phx.server
```

Make sure your Phoenix endpoint reads `PORT` in dev, for example:

```elixir
config :my_app, MyAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: ["https://my-app.localhost:4443"]
```

The development CA and host certificates live under `~/.gatehouse/dev_certs` by
default. `mix gatehouse.trust` creates the CA and prints OS-specific trust-store
instructions; it does not run `sudo` automatically. See
[`docs/phoenix-dev.md`](docs/phoenix-dev.md) for details and troubleshooting.

## Development

This project was created with Igniter and VibeKit:

```sh
mix igniter.new gatehouse --sup --install vibe_kit --yes
```

Run checks with:

```sh
mix ci
```

## Near-term roadmap

1. Resolve upstream Livery/Barrel MCP dependency blockers and publish the first
   usable Gatehouse Hex release.
2. Add richer telemetry dashboards/examples.
3. Add load and stress test scenarios for HTTP, WebSocket, blue-green switching,
   and ACME challenge routing.
4. Add load-balancing policies beyond one active target.
5. Add full multi-target runtime load balancing beyond the config shape.
