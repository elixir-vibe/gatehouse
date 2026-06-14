# Load and stress testing

Gatehouse load tests should exercise both the external proxy surface and the
BEAM internals that make blue-green switching and SafeRPC routing interesting.
Use external load generators for raw pressure, but keep an Elixir harness as the
orchestrator and source of correctness assertions.

## Tooling strategy

Use a hybrid setup:

- **Elixir harness** — starts Gatehouse, local backends, SafeRPC servers, applies
  route config, attaches telemetry handlers, checks correctness, and samples VM
  stats.
- **`wrk` or `bombardier`** — raw HTTP throughput and latency pressure.
- **`vegeta`** — constant-rate and soak tests.
- **`k6`** — scripted WebSocket and mixed-user scenarios.

The built-in harness is intentionally dependency-light and can generate local
concurrent HTTP traffic itself. External tools can be added around the same
scenarios once the baseline is stable.

## Built-in harness

Run from the project root:

```sh
mix run scripts/load_test_gatehouse.exs --scenario safe_rpc_baseline --requests 5000 --concurrency 100
```

Available scenarios:

- `http_baseline` — Gatehouse routes to a local HTTP backend.
- `safe_rpc_baseline` — Gatehouse routes HTTP requests to a SafeRPC Unix socket
  backend.
- `safe_rpc_blue_green` — traffic starts on a blue SafeRPC backend, switches to a
  green SafeRPC backend during load, and verifies both phases.
- `safe_rpc_failure` — Gatehouse points at a missing SafeRPC socket and verifies
  failure behavior is surfaced as gateway errors without crashing the proxy.

Common options:

```sh
--scenario NAME       Scenario to run; default: safe_rpc_baseline
--requests N         Total requests; default: 1000
--concurrency N      Concurrent client tasks; default: 50
--path PATH          Request path; default: /bench
```

## Metrics collected

The harness attaches to Gatehouse telemetry and reports:

- `[:gatehouse, :proxy, :request, :stop]`
- `[:gatehouse, :safe_rpc, :pool, :checkout, :stop]`
- `[:gatehouse, :safe_rpc, :request, :stop]`
- `[:gatehouse, :deploy, :stop]`
- `[:gatehouse, :health_check, :stop]`

It also reports client-side latency, status counts, BEAM process count, memory,
and reduction count before and after the scenario.

For SafeRPC scenarios, compare:

- client latency — end-to-end observed by the caller;
- Gatehouse proxy latency — routing + upstream + response conversion;
- SafeRPC request latency — SafeRPC call only;
- SafeRPC pool checkout latency — client pool lookup/open overhead.

## External load generators

Once a scenario is running, point external tools at the printed Gatehouse URL and
set the route host header.

Example with `bombardier`:

```sh
bombardier -c 200 -d 30s -H 'Host: safe-rpc-bench.localhost' http://127.0.0.1:PORT/bench
```

Example with `wrk`:

```sh
wrk -t8 -c400 -d30s -H 'Host: safe-rpc-bench.localhost' http://127.0.0.1:PORT/bench
```

Example with `vegeta`:

```sh
printf 'GET http://127.0.0.1:PORT/bench\nHost: safe-rpc-bench.localhost\n' \
  | vegeta attack -rate 5000/s -duration 60s \
  | tee results.bin \
  | vegeta report
```

## Stress cases to add next

1. WebSocket echo and long-lived connection churn.
2. Streaming and slow-response backends.
3. SafeRPC backend crash/restart during load.
4. Blue-green switching while requests are in flight.
5. Soak tests with process/memory leak assertions.
6. Livery `instrument` metrics exporter wiring for lower-level HTTP server
   metrics.
