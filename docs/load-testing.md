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
concurrent HTTP traffic itself. It can also start external load generators for
you when they are installed on `PATH`, while still collecting Gatehouse telemetry
and VM samples from the same run.

## Built-in harness

Run from the project root:

```sh
mix run scripts/load_test_gatehouse.exs --scenario safe_rpc_baseline --requests 5000 --concurrency 100
```

Available scenarios:

- `direct_http_baseline` — load generator routes directly to the local HTTP
  backend, bypassing Gatehouse, for an apples-to-apples local overhead check.
- `http_baseline` — Gatehouse routes to a local HTTP backend.
- `ws_echo` — Gatehouse proxies WebSocket upgrades to a local echo backend and
  verifies concurrent echo round trips. This scenario currently requires the
  built-in driver; use k6 later for external WebSocket stress.
- `safe_rpc_baseline` — Gatehouse routes HTTP requests to a SafeRPC Unix socket
  backend.
- `safe_rpc_blue_green` — traffic starts on a blue SafeRPC backend, switches to a
  green SafeRPC backend during load, and verifies both phases.
- `safe_rpc_restart` — traffic starts on a SafeRPC backend, the backend is
  stopped mid-run, then restarted on the same socket to exercise pool
  invalidation and recovery. This scenario requires the built-in driver because
  the harness coordinates the restart per request.
- `safe_rpc_failure` — Gatehouse points at a missing SafeRPC socket and verifies
  failure behavior is surfaced as gateway errors without crashing the proxy.

Common options:

```sh
--scenario NAME       Scenario to run; default: safe_rpc_baseline
--requests N         Total requests; default: 1000
--concurrency N      Concurrent client tasks; default: 50
--path PATH          Request path; default: /bench
--driver DRIVER      Load driver: builtin, bombardier, wrk, or vegeta; default: builtin
--duration DURATION  Duration for wrk/vegeta drivers; default: 30s
--rate RATE          Constant rate for vegeta; default: 1000/s
--sample-interval MS Periodic VM/process sampling interval; default: 1000
--settle-ms MS       Time to wait after load before retained-memory sample; default: 1000
--no-gc              Disable forced garbage collection before/after settle
--max-error-rate N   Fail if proxy error rate is above N, e.g. 0 or 0.01
--max-proxy-p99-ms N Fail if sampled proxy p99 latency is above N milliseconds
--max-retained-total-mb N Fail if retained total memory exceeds N MiB
--max-retained-processes N Fail if retained process count exceeds N
--process-diagnostics Print retained process groups and largest retained processes
--profile eprof      Run the load phase under Erlang `:eprof` and print totals
```

## Metrics collected

The harness attaches to Gatehouse telemetry and reports:

- `[:gatehouse, :proxy, :request, :stop]`
- `[:gatehouse, :safe_rpc, :pool, :checkout, :stop]`
- `[:gatehouse, :safe_rpc, :request, :stop]`
- `[:gatehouse, :deploy, :stop]`
- `[:gatehouse, :health_check, :stop]`

It also reports client-side latency, status counts, BEAM process count, memory,
and reduction count before load, immediately after load, and after a settle
period. By default the harness forces garbage collection before and after the
settle wait so retained-memory deltas are easier to spot. During the run it
samples VM state periodically, including total memory, memory breakdown, process
count, reductions, and the top memory-consuming processes in the last sample.

Telemetry event counts, statuses, and result counts are exact. Duration
percentiles are calculated from a bounded reservoir sample of up to 10,000
measurements per event so long stress runs do not turn the collector into the
main memory consumer. Optional threshold flags turn the harness into a CI-style
performance guard by raising on excessive error rate, proxy p99 latency,
retained memory, or retained process growth.

For SafeRPC scenarios, compare:

- client latency — end-to-end observed by the caller;
- Gatehouse proxy latency — routing + upstream + response conversion;
- SafeRPC request latency — SafeRPC call only;
- SafeRPC pool checkout latency — client pool lookup/open overhead.

For profiling, prefer external drivers such as `bombardier` with `--profile
eprof`. Profiling the built-in driver includes the Elixir client workload and can
produce misleading results or exaggerate peer-close timing. External drivers keep
`:eprof` focused on Gatehouse, Livery, Gun, and SafeRPC server work.

## External load generators

The harness can start external tools directly. This keeps the target Gatehouse
node instrumented while load is generated by another executable.

Example with `bombardier`:

```sh
mix run scripts/load_test_gatehouse.exs \
  --scenario safe_rpc_baseline \
  --driver bombardier \
  --requests 100000 \
  --concurrency 200
```

Example with `wrk`:

```sh
mix run scripts/load_test_gatehouse.exs \
  --scenario safe_rpc_baseline \
  --driver wrk \
  --duration 30s \
  --concurrency 400
```

Example with `vegeta`:

```sh
mix run scripts/load_test_gatehouse.exs \
  --scenario safe_rpc_baseline \
  --driver vegeta \
  --rate 5000/s \
  --duration 60s
```

If the selected executable is not installed or not on `PATH`, the harness fails
fast with a clear error.

## Local baseline results

These are development-machine baselines, not release guarantees. They are useful
for spotting large regressions while Gatehouse is still pre-release.

Environment:

- local Linux development machine
- Gatehouse run with `mix run`
- `bombardier --http1` for external HTTP pressure
- `--requests 100000 --concurrency 200` for HTTP/SafeRPC baselines
- bounded telemetry duration reservoirs, so p99 values are sampled on 100k runs

| Scenario | Driver | Requests | Concurrency | Result | Throughput | Proxy p50 | Proxy p95 | Proxy p99 | Retained total | Retained processes |
| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `direct_http_baseline` | bombardier | 100,000 | 200 | 100% 2xx | ~108.3k req/s | n/a | n/a | n/a | +2.53MiB | +0 |
| `http_baseline` | bombardier | 100,000 | 200 | 100% 2xx | ~28.0k req/s | 0.21ms | 1.55ms | 4.28ms | +7.01MiB | +134 |
| `safe_rpc_baseline` | bombardier | 100,000 | 200 | 100% 2xx | ~12.3k req/s | 8.88ms | 20.69ms | 29.49ms | +0.67MiB | +37 |
| `ws_echo` | builtin | 10,000 | 200 | 10,000 echoes | n/a | 4.96ms | 9.28ms | 42.56ms | +6.49MiB | +38 |
| `safe_rpc_restart` | builtin | 10,000 | 100 | 6,718 2xx / 3,282 502 | n/a | 0.27ms | 2.55ms | 6.40ms | +3.48MiB | +39 |

The direct HTTP baseline shows the local Livery backend can serve about 108k
req/s on this machine. Gatehouse HTTP proxying is about 26% of direct backend
throughput after adding a bounded per-origin upstream connection pool
(`:backend_max_connections_per_origin`, default 32) and caching active target
snapshots in the ETS route table. That is a meaningful improvement over the
initial ~18k req/s baseline, but HTTP proxy performance remains an optimization
area.

`safe_rpc_restart` initially appeared to retain about +201MiB and +141
processes. `--process-diagnostics` showed those retained processes were mostly
client-side Req/Finch connection-pool processes created by the built-in harness,
not Gatehouse/SafeRPC server processes. The built-in HTTP client now uses
`:httpc` with `connection: close` so restart leak checks measure the proxy more
cleanly.

The latest 10,000 request / 100 concurrency restart run recovered correctly:

- responses: 6,718 successful, 3,282 expected `502 bad gateway` during outage
- proxy p99: 6.40ms
- retained total memory: about +3.48MiB
- retained process count: +39

The remaining retained processes are the Gatehouse/Livery listener and acceptor
processes kept alive for the configured route.

A small `:eprof` pass using `bombardier` showed current hotspots are mostly in
network I/O and HTTP parsing rather than Gatehouse business logic:

- HTTP proxy: `erts_internal:port_command/3`, H1 header lowercasing/parsing,
  `binary:match/2`, and `String.downcase/3`. Earlier profiles also showed
  per-checkout connection-pool liveness scans and service checkout calls; the
  backend pool now keeps a tuple-backed round-robin pool and route ETS entries
  carry active target snapshots so ordinary requests avoid service-process
  checkout/checkin coordination.
- SafeRPC proxy: `erts_internal:port_control/3`, `port_command/3`,
  `gen:do_call/4`, telemetry sample collection, H1 parsing, and ETF
  encode/decode.

## Stress cases to add next

1. Long-lived WebSocket connection churn and mixed message sizes.
2. Streaming and slow-response backends.
3. Soak tests with process/memory leak assertions.
4. Livery `instrument` metrics exporter wiring for lower-level HTTP server
   metrics.
