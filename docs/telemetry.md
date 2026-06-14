# Telemetry events

`gatehouse` emits events under the `[:gatehouse]` prefix.

## Quick attach example

```elixir
handler = fn event, measurements, metadata, _config ->
  duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)
  Logger.info("#{inspect(event)} #{duration_ms}ms #{inspect(metadata)}")
end

:telemetry.attach_many(
  "gatehouse-logger",
  [
    [:gatehouse, :deploy, :stop],
    [:gatehouse, :health_check, :stop],
    [:gatehouse, :proxy, :request, :stop],
    [:gatehouse, :drain, :stop],
    [:gatehouse, :acme, :renewal, :stop]
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
[:gatehouse, :deploy, :stop]
```

Measurements:

- `:duration` — native monotonic duration

Metadata:

- `:service`
- `:result`

## Health checks

```elixir
[:gatehouse, :health_check, :stop]
```

Measurements:

- `:duration`

Metadata:

- `:target_id`
- `:url`
- `:result`

## Drains

```elixir
[:gatehouse, :drain, :stop]
```

Metadata:

- `:service`
- `:target_id`

## Backend connection pool

```elixir
[:gatehouse, :backend, :pool, :open]
[:gatehouse, :backend, :pool, :invalidate]
[:gatehouse, :backend, :pool, :reap]
[:gatehouse, :backend, :pool, :evict]
```

Metadata:

- `:key` — `{scheme, host, port}`

## ACME renewals

```elixir
[:gatehouse, :acme, :renewal, :tick]
[:gatehouse, :acme, :renewal, :stop]
```

Stop metadata:

- `:name`
- `:result` — `:ok`, `{:skip, :not_due}`, or `{:error, reason}`

A successful renewal persists the certificate and refreshes the Livery TLS listener.

## Proxy requests

```elixir
[:gatehouse, :proxy, :request, :stop]
```

Measurements:

- `:duration`

Metadata:

- `:service`
- `:target_id`
- `:status`
- optional `:error`
