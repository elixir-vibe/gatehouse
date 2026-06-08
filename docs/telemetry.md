# Telemetry events

`xamal_proxy` emits events under the `[:xamal_proxy]` prefix.

## Deploy

```elixir
[:xamal_proxy, :deploy, :stop]
```

Measurements:

- `:duration` — native monotonic duration

Metadata:

- `:service`
- `:result`

## Health checks

```elixir
[:xamal_proxy, :health_check, :stop]
```

Measurements:

- `:duration`

Metadata:

- `:target_id`
- `:url`
- `:result`

## Drains

```elixir
[:xamal_proxy, :drain, :stop]
```

Metadata:

- `:service`
- `:target_id`

## Backend connection pool

```elixir
[:xamal_proxy, :backend, :pool, :open]
[:xamal_proxy, :backend, :pool, :invalidate]
[:xamal_proxy, :backend, :pool, :reap]
```

Metadata:

- `:key` — `{scheme, host, port}`

## Proxy requests

```elixir
[:xamal_proxy, :proxy, :request, :stop]
```

Measurements:

- `:duration`

Metadata:

- `:service`
- `:target_id`
- `:status`
- optional `:error`
