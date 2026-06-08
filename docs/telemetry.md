# Telemetry events

`xamal_proxy` emits events under the `[:xamal_proxy]` prefix.

## Quick attach example

```elixir
handler = fn event, measurements, metadata, _config ->
  duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)
  Logger.info("#{inspect(event)} #{duration_ms}ms #{inspect(metadata)}")
end

:telemetry.attach_many(
  "xamal-proxy-logger",
  [
    [:xamal_proxy, :deploy, :stop],
    [:xamal_proxy, :health_check, :stop],
    [:xamal_proxy, :proxy, :request, :stop],
    [:xamal_proxy, :drain, :stop],
    [:xamal_proxy, :acme, :renewal, :stop]
  ],
  handler,
  nil
)
```

## Dashboard sketch

Useful first panels:

- request rate grouped by `metadata.service`
- p50/p95/p99 request duration from `[:proxy, :request, :stop]`
- 5xx count grouped by `metadata.status`
- deploy duration and result grouped by `metadata.service`
- health-check failures grouped by `metadata.url`
- backend pool opens/reaps/evictions grouped by `metadata.key`
- active drain count from drain start/stop events once drain start is added
- ACME renewal outcomes grouped by certificate `metadata.name`

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
[:xamal_proxy, :backend, :pool, :evict]
```

Metadata:

- `:key` — `{scheme, host, port}`

## ACME renewals

```elixir
[:xamal_proxy, :acme, :renewal, :tick]
[:xamal_proxy, :acme, :renewal, :stop]
```

Stop metadata:

- `:name`
- `:result` — `:ok`, `{:skip, :not_due}`, or `{:error, reason}`

A successful renewal persists the certificate and refreshes the Livery TLS listener.

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
