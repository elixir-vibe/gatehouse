#!/usr/bin/env elixir

defmodule Gatehouse.LoadTest.SafeRPCService do
  @behaviour SafeRPC.Adapter.Service

  alias SafeRPC.Adapter.HTTP.{Request, Response}

  @impl true
  def init(opts), do: {:ok, %{label: Keyword.fetch!(opts, :label)}}

  @impl true
  def call(:http_request, %Request{path: path}, _meta, %{label: label}) do
    {:ok, Response.text(200, "#{label} #{path}", [{"content-type", "text/plain"}])}
  end
end

defmodule Gatehouse.LoadTest.SafeRPCServer do
  use SafeRPC.Adapter.Server, service: Gatehouse.LoadTest.SafeRPCService
end

defmodule Gatehouse.LoadTest.TelemetryCollector do
  @max_duration_samples 10_000

  @events [
    [:gatehouse, :proxy, :request, :stop],
    [:gatehouse, :safe_rpc, :pool, :checkout, :stop],
    [:gatehouse, :safe_rpc, :request, :stop],
    [:gatehouse, :deploy, :stop],
    [:gatehouse, :health_check, :stop]
  ]

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def attach do
    :telemetry.detach(handler_id())

    :telemetry.attach_many(
      handler_id(),
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def detach, do: :telemetry.detach(handler_id())

  def handle_event(event, measurements, metadata, _config) do
    duration = measurements[:duration]

    Agent.update(__MODULE__, fn state ->
      update_in(
        state,
        [Access.key(event, %{count: 0, durations: [], statuses: %{}, results: %{}})],
        fn summary ->
          summary
          |> Map.update!(:count, &(&1 + 1))
          |> maybe_add_duration(duration)
          |> update_status(metadata[:status])
          |> update_result(metadata[:result])
        end
      )
    end)
  end

  def snapshot, do: Agent.get(__MODULE__, & &1)

  defp handler_id, do: "gatehouse-load-test-telemetry"

  defp maybe_add_duration(summary, nil), do: summary

  defp maybe_add_duration(summary, duration) do
    Map.update!(summary, :durations, &sample_duration(&1, duration, summary.count))
  end

  defp sample_duration(durations, duration, _count)
       when length(durations) < @max_duration_samples do
    [duration | durations]
  end

  defp sample_duration(durations, duration, count) do
    slot = :rand.uniform(count)

    if slot <= @max_duration_samples do
      List.replace_at(durations, slot - 1, duration)
    else
      durations
    end
  end

  defp update_status(summary, nil), do: summary

  defp update_status(summary, status) do
    Map.update!(summary, :statuses, &Map.update(&1, status, 1, fn count -> count + 1 end))
  end

  defp update_result(summary, nil), do: summary

  defp update_result(summary, result) do
    key = inspect(result)
    Map.update!(summary, :results, &Map.update(&1, key, 1, fn count -> count + 1 end))
  end
end

defmodule Gatehouse.LoadTest.VMSampler do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @impl true
  def init(opts) do
    interval = Keyword.fetch!(opts, :interval)
    state = %{interval: interval, samples: [sample()]}
    schedule(interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    schedule(state.interval)
    {:noreply, %{state | samples: [sample() | state.samples]}}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:stop, :normal, Enum.reverse([sample() | state.samples]), state}
  end

  defp schedule(interval), do: Process.send_after(self(), :sample, interval)

  defp sample do
    %{
      at_native: System.monotonic_time(),
      process_count: :erlang.system_info(:process_count),
      memory: :erlang.memory() |> Map.new(),
      reductions: elem(:erlang.statistics(:reductions), 0),
      top_processes: top_processes()
    }
  end

  defp top_processes do
    Process.list()
    |> Enum.map(&process_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory, :desc)
    |> Enum.take(5)
  end

  defp process_summary(pid) do
    with info when is_list(info) <-
           Process.info(pid, [:registered_name, :current_function, :message_queue_len, :memory]) do
      %{
        pid: inspect(pid),
        name: info[:registered_name],
        current_function: info[:current_function],
        message_queue_len: info[:message_queue_len],
        memory: info[:memory]
      }
    else
      _other -> nil
    end
  end
end

defmodule Gatehouse.LoadTest.WebSocketEchoHandler do
  @behaviour :ws_handler

  def init(_request, _opts), do: {:ok, nil}

  def handle_in({:text, data}, state), do: {:reply, [{:text, data}], state}
  def handle_in({:binary, data}, state), do: {:reply, [{:binary, data}], state}
  def handle_in({:ping, data}, state), do: {:reply, [{:pong, data}], state}
  def handle_in({:close, code, _reason}, state), do: {:stop, {:peer_closed, code}, state}
  def handle_in(_frame, state), do: {:ok, state}

  def handle_info(_message, state), do: {:ok, state}
  def terminate(_reason, _state), do: :ok
end

defmodule Gatehouse.LoadTest.HTTPBackend do
  alias Gatehouse.Livery
  alias Gatehouse.Livery.{Request, Response}

  def start_link(label) do
    handler = fn request ->
      case Request.path(request) do
        "/stream" ->
          Response.stream(200, [{"content-type", "text/plain"}], fn emit ->
            emit.("#{label}:start\n")
            Process.sleep(200)
            emit.("#{label}:end\n")
          end)

        _path ->
          Response.text(200, "#{label} #{Request.path(request)}")
      end
    end

    with {:ok, service} <-
           Livery.start_service(%{
             http: %{ip: {127, 0, 0, 1}, port: 0},
             handler: handler
           }) do
      {:ok, %{service: service, port: Livery.listeners(service).h1}}
    end
  end

  def stop(%{service: service}), do: Livery.stop_service(service)
end

defmodule Gatehouse.LoadTest.WebSocketBackend do
  alias Gatehouse.Livery
  alias Gatehouse.Livery.{Request, Response, WebSocket}

  def start_link(label) do
    handler = fn request ->
      case Request.path(request) do
        "/ws" -> WebSocket.upgrade(request, Gatehouse.LoadTest.WebSocketEchoHandler, %{})
        "/up" -> Response.text(200, "ok")
        _path -> Response.text(200, "#{label} #{Request.path(request)}")
      end
    end

    with {:ok, service} <-
           Livery.start_service(%{
             http: %{ip: {127, 0, 0, 1}, port: 0},
             handler: handler
           }) do
      {:ok, %{service: service, port: Livery.listeners(service).h1}}
    end
  end

  def stop(%{service: service}), do: Livery.stop_service(service)
end

defmodule Gatehouse.LoadTest do
  alias Gatehouse.LoadTest.{
    HTTPBackend,
    SafeRPCServer,
    TelemetryCollector,
    VMSampler,
    WebSocketBackend
  }

  def main(argv) do
    opts = parse_args(argv)
    ensure_started!()
    {:ok, _collector} = TelemetryCollector.start_link([])
    TelemetryCollector.attach()

    {:ok, _sampler} = VMSampler.start_link(interval: opts.sample_interval)
    before_vm = vm_stats()
    before_processes = process_snapshot()

    try do
      start_profile(opts.profile)
      result = run(opts)
      profile_report = stop_profile(opts.profile)
      after_load_vm = vm_stats()
      settled_vm = settle_vm(opts)
      samples = VMSampler.stop()
      telemetry = TelemetryCollector.snapshot()

      print_report(
        result,
        telemetry,
        before_vm,
        after_load_vm,
        settled_vm,
        samples,
        before_processes,
        process_snapshot(),
        opts,
        profile_report
      )

      assert_thresholds!(opts, telemetry, before_vm, settled_vm)
    after
      TelemetryCollector.detach()
    end
  end

  defp parse_args(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        strict: [
          scenario: :string,
          requests: :integer,
          concurrency: :integer,
          path: :string,
          sample_interval: :integer,
          settle_ms: :integer,
          gc: :boolean,
          driver: :string,
          duration: :string,
          rate: :string,
          max_error_rate: :float,
          max_proxy_p99_ms: :float,
          max_retained_total_mb: :float,
          max_retained_processes: :integer,
          process_diagnostics: :boolean,
          profile: :string
        ]
      )

    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")

    %{
      scenario: Keyword.get(opts, :scenario, "safe_rpc_baseline"),
      requests: Keyword.get(opts, :requests, 1_000),
      concurrency: Keyword.get(opts, :concurrency, 50),
      path: Keyword.get(opts, :path, "/bench"),
      sample_interval: Keyword.get(opts, :sample_interval, 1_000),
      settle_ms: Keyword.get(opts, :settle_ms, 1_000),
      gc?: Keyword.get(opts, :gc, true),
      driver: Keyword.get(opts, :driver, "builtin"),
      duration: Keyword.get(opts, :duration, "30s"),
      rate: Keyword.get(opts, :rate, "1000/s"),
      max_error_rate: Keyword.get(opts, :max_error_rate),
      max_proxy_p99_ms: Keyword.get(opts, :max_proxy_p99_ms),
      max_retained_total_mb: Keyword.get(opts, :max_retained_total_mb),
      max_retained_processes: Keyword.get(opts, :max_retained_processes),
      process_diagnostics?: Keyword.get(opts, :process_diagnostics, false),
      profile: Keyword.get(opts, :profile)
    }
  end

  defp ensure_started! do
    {:ok, _} = Application.ensure_all_started(:gatehouse)
    {:ok, _} = Application.ensure_all_started(:inets)
  end

  defp run(%{scenario: "direct_http_baseline"} = opts), do: direct_http_baseline(opts)
  defp run(%{scenario: "http_baseline"} = opts), do: http_baseline(opts)
  defp run(%{scenario: "http_stream_churn"} = opts), do: http_stream_churn(opts)
  defp run(%{scenario: "ws_echo"} = opts), do: ws_echo(opts)
  defp run(%{scenario: "ws_churn"} = opts), do: ws_churn(opts)
  defp run(%{scenario: "safe_rpc_baseline"} = opts), do: safe_rpc_baseline(opts)
  defp run(%{scenario: "safe_rpc_blue_green"} = opts), do: safe_rpc_blue_green(opts)
  defp run(%{scenario: "safe_rpc_restart"} = opts), do: safe_rpc_restart(opts)
  defp run(%{scenario: "safe_rpc_failure"} = opts), do: safe_rpc_failure(opts)
  defp run(%{scenario: scenario}), do: raise("unknown scenario: #{scenario}")

  defp direct_http_baseline(opts) do
    {:ok, backend} = HTTPBackend.start_link("direct_http")
    host = "direct-http-bench.localhost"
    Process.put(:gatehouse_load_port, backend.port)

    IO.puts("Direct backend listening at http://127.0.0.1:#{backend.port}/")

    result = run_load(opts, host)
    HTTPBackend.stop(backend)
    Map.put(result, :scenario, "direct_http_baseline")
  end

  defp http_baseline(opts) do
    {:ok, backend} = HTTPBackend.start_link("http")
    host = "http-bench.localhost"

    start_gatehouse!(%{
      host: host,
      target: "http://127.0.0.1:#{backend.port}",
      kind: :http
    })

    result = run_load(opts, host)
    HTTPBackend.stop(backend)
    Map.put(result, :scenario, "http_baseline")
  end

  defp http_stream_churn(%{driver: driver}) when driver != "builtin" do
    raise "http_stream_churn requires --driver builtin so the harness can switch targets during in-flight streams"
  end

  defp http_stream_churn(opts) do
    {:ok, blue} = HTTPBackend.start_link("blue")
    {:ok, green} = HTTPBackend.start_link("green")
    host = "http-stream-churn.localhost"
    service = :http_stream_churn

    start_gatehouse!(%{
      host: host,
      target: "http://127.0.0.1:#{blue.port}",
      kind: :http,
      service: service
    })

    port = Process.get(:gatehouse_load_port)
    url = "http://127.0.0.1:#{port}/stream"
    switch_after = max(1, div(opts.requests, 2))
    counter = :atomics.new(1, [])
    switched = :atomics.new(1, [])

    results =
      1..opts.requests
      |> Task.async_stream(
        fn _index ->
          current = :atomics.add_get(counter, 1, 1)

          if current >= switch_after and :atomics.compare_exchange(switched, 1, 0, 1) == :ok do
            apply_http_config!(host, "http://127.0.0.1:#{green.port}", service)
          end

          request_once(url, host)
        end,
        max_concurrency: opts.concurrency,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    verify = request_once("http://127.0.0.1:#{port}/bench", host)

    HTTPBackend.stop(blue)
    HTTPBackend.stop(green)

    %{
      requests: opts.requests,
      concurrency: opts.concurrency,
      url: url,
      host: host,
      statuses: frequencies(Enum.map(results, & &1.status)),
      bodies: frequencies(Enum.map(results, & &1.body)),
      client_durations: Enum.map(results, & &1.duration),
      switch_after: switch_after,
      verify_after_switch: verify.body
    }
    |> Map.put(:scenario, "http_stream_churn")
  end

  defp ws_echo(%{driver: driver}) when driver != "builtin" do
    raise "ws_echo requires --driver builtin; use k6 later for external WebSocket stress"
  end

  defp ws_echo(opts) do
    {:ok, backend} = WebSocketBackend.start_link("ws")
    host = "ws-echo.localhost"

    start_gatehouse!(%{
      host: host,
      target: "http://127.0.0.1:#{backend.port}",
      kind: :http
    })

    result = run_websocket_clients(opts, host)
    WebSocketBackend.stop(backend)
    Map.put(result, :scenario, "ws_echo")
  end

  defp ws_churn(%{driver: driver}) when driver != "builtin" do
    raise "ws_churn requires --driver builtin; use k6 later for external WebSocket churn"
  end

  defp ws_churn(opts) do
    {:ok, backend} = WebSocketBackend.start_link("ws_churn")
    host = "ws-churn.localhost"

    start_gatehouse!(%{
      host: host,
      target: "http://127.0.0.1:#{backend.port}",
      kind: :http
    })

    result = run_websocket_churn(opts, host)
    WebSocketBackend.stop(backend)
    Map.put(result, :scenario, "ws_churn")
  end

  defp safe_rpc_baseline(opts) do
    socket = socket_path("baseline")
    File.rm(socket)
    {:ok, server} = SafeRPCServer.start_link(socket: socket, label: "safe_rpc")
    host = "safe-rpc-bench.localhost"

    start_gatehouse!(%{host: host, target: socket, kind: :safe_rpc})

    result = run_load(opts, host)
    GenServer.stop(server)
    Map.put(result, :scenario, "safe_rpc_baseline")
  end

  defp safe_rpc_blue_green(opts) do
    blue_socket = socket_path("blue")
    green_socket = socket_path("green")
    File.rm(blue_socket)
    File.rm(green_socket)
    {:ok, blue} = SafeRPCServer.start_link(socket: blue_socket, label: "blue")
    {:ok, green} = SafeRPCServer.start_link(socket: green_socket, label: "green")
    host = "safe-rpc-blue-green.localhost"

    start_gatehouse!(%{host: host, target: blue_socket, kind: :safe_rpc, service: :safe_rpc_bg})

    switch_at = div(opts.requests, 2)
    counter = :atomics.new(1, [])
    switched = :atomics.new(1, [])

    result =
      run_load(opts, host, fn index ->
        current = :atomics.add_get(counter, 1, 1)

        if current >= switch_at and :atomics.compare_exchange(switched, 1, 0, 1) == :ok do
          apply_safe_rpc_config!(host, green_socket, :safe_rpc_bg)
        end

        index
      end)

    GenServer.stop(blue)
    GenServer.stop(green)

    result
    |> Map.put(:scenario, "safe_rpc_blue_green")
    |> Map.put(:blue_green_bodies, result.bodies)
  end

  defp safe_rpc_restart(%{driver: driver}) when driver != "builtin" do
    raise "safe_rpc_restart requires --driver builtin so the harness can restart the backend during request generation"
  end

  defp safe_rpc_restart(opts) do
    socket = socket_path("restart")
    File.rm(socket)
    {:ok, server} = SafeRPCServer.start_link(socket: socket, label: "before_restart")
    server_ref = Agent.start_link(fn -> server end) |> elem(1)
    host = "safe-rpc-restart.localhost"

    start_gatehouse!(%{host: host, target: socket, kind: :safe_rpc, service: :safe_rpc_restart})

    stop_at = max(1, div(opts.requests, 3))
    restart_at = max(stop_at + 1, div(opts.requests * 2, 3))
    counter = :atomics.new(1, [])
    stopped = :atomics.new(1, [])
    restarted = :atomics.new(1, [])

    result =
      run_load(opts, host, fn index ->
        current = :atomics.add_get(counter, 1, 1)

        if current >= stop_at and :atomics.compare_exchange(stopped, 1, 0, 1) == :ok do
          Agent.get_and_update(server_ref, fn pid ->
            GenServer.stop(pid)
            {pid, nil}
          end)
        end

        if current >= restart_at and :atomics.compare_exchange(restarted, 1, 0, 1) == :ok do
          File.rm(socket)

          {:ok, restarted_server} =
            SafeRPCServer.start_link(socket: socket, label: "after_restart")

          Agent.update(server_ref, fn _pid -> restarted_server end)
        end

        index
      end)

    Agent.get(server_ref, & &1)
    |> case do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _nil -> :ok
    end

    Agent.stop(server_ref)

    result
    |> Map.put(:scenario, "safe_rpc_restart")
    |> Map.put(:restart_points, %{stop_at: stop_at, restart_at: restart_at})
  end

  defp safe_rpc_failure(opts) do
    socket = socket_path("missing")
    File.rm(socket)
    host = "safe-rpc-failure.localhost"

    start_gatehouse!(%{host: host, target: socket, kind: :safe_rpc})

    opts
    |> run_load(host)
    |> Map.put(:scenario, "safe_rpc_failure")
  end

  defp start_gatehouse!(config) do
    {:ok, listener} =
      Gatehouse.LiveryListener.start_link(port: 0, name: unique_name(:gatehouse_load))

    port = Gatehouse.LiveryListener.port(listener)

    case config.kind do
      :http ->
        apply_http_config!(config.host, config.target, Map.get(config, :service, :bench))

      :safe_rpc ->
        apply_safe_rpc_config!(config.host, config.target, Map.get(config, :service, :bench))
    end

    Process.put(:gatehouse_load_port, port)
    Process.put(:gatehouse_load_listener, listener)
    IO.puts("Gatehouse listening at http://127.0.0.1:#{port}/ with Host: #{config.host}")
    {:ok, port}
  end

  defp apply_http_config!(host, target_url, service) do
    config =
      Gatehouse.Config.eval!("""
      import Gatehouse.Config

      service #{inspect(service)} do
        host #{inspect(host)}
        target :main, #{inspect(target_url)}, active: true
      end
      """)

    :ok = Gatehouse.Control.apply_config(config)
  end

  defp apply_safe_rpc_config!(host, socket, service) do
    config =
      Gatehouse.Config.eval!("""
      import Gatehouse.Config

      service #{inspect(service)} do
        host #{inspect(host)}
        target :main, safe_rpc: [socket: #{inspect(socket)}, shards: 4], active: true
      end
      """)

    :ok = Gatehouse.Control.apply_config(config)
  end

  defp run_load(opts, host, before_request \\ fn index -> index end)

  defp run_load(%{driver: "builtin"} = opts, host, before_request) do
    port = Process.get(:gatehouse_load_port)
    url = "http://127.0.0.1:#{port}#{opts.path}"

    results =
      1..opts.requests
      |> Task.async_stream(
        fn index ->
          before_request.(index)
          request_once(url, host)
        end,
        max_concurrency: opts.concurrency,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    %{
      requests: opts.requests,
      concurrency: opts.concurrency,
      url: url,
      host: host,
      statuses: frequencies(Enum.map(results, & &1.status)),
      bodies: frequencies(Enum.map(results, & &1.body)),
      client_durations: Enum.map(results, & &1.duration)
    }
  end

  defp run_load(%{driver: driver} = opts, host, _before_request)
       when driver in ["bombardier", "wrk", "vegeta"] do
    port = Process.get(:gatehouse_load_port)
    url = "http://127.0.0.1:#{port}#{opts.path}"
    output = run_external_driver!(driver, opts, url, host)

    %{
      requests: opts.requests,
      concurrency: opts.concurrency,
      url: url,
      host: host,
      driver: driver,
      statuses: %{},
      bodies: %{},
      client_durations: [],
      external_output: output
    }
  end

  defp run_load(%{driver: driver}, _host, _before_request) do
    raise "unknown load driver #{inspect(driver)}; expected builtin, bombardier, wrk, or vegeta"
  end

  defp run_external_driver!("bombardier", opts, url, host) do
    run_tool!("bombardier", [
      "--http1",
      "-c",
      to_string(opts.concurrency),
      "-n",
      to_string(opts.requests),
      "-H",
      "Host: #{host}",
      url
    ])
  end

  defp run_external_driver!("wrk", opts, url, host) do
    threads = max(1, System.schedulers_online())

    run_tool!("wrk", [
      "-t#{threads}",
      "-c#{opts.concurrency}",
      "-d#{opts.duration}",
      "-H",
      "Host: #{host}",
      url
    ])
  end

  defp run_external_driver!("vegeta", opts, url, host) do
    target = "GET #{url}\nHost: #{host}\n"

    run_tool!("sh", [
      "-c",
      "printf '%s' \"$1\" | vegeta attack -rate \"$2\" -duration \"$3\" | vegeta report",
      "vegeta-gatehouse",
      target,
      opts.rate,
      opts.duration
    ])
  end

  defp run_tool!(tool, args) do
    case System.find_executable(tool) do
      nil ->
        raise "#{tool} is not installed or not on PATH"

      _path ->
        case System.cmd(tool, args, stderr_to_stdout: true) do
          {output, 0} -> output
          {output, status} -> raise "#{tool} failed with #{status}:\n#{output}"
        end
    end
  end

  defp run_websocket_clients(opts, host) do
    port = Process.get(:gatehouse_load_port)
    path = opts.path || "/ws"
    ws_path = if path == "/bench", do: "/ws", else: path

    results =
      1..opts.requests
      |> Task.async_stream(
        fn index -> websocket_echo_once(port, host, ws_path, "ws-#{index}") end,
        max_concurrency: opts.concurrency,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    %{
      requests: opts.requests,
      concurrency: opts.concurrency,
      url: "ws://127.0.0.1:#{port}#{ws_path}",
      host: host,
      statuses: frequencies(Enum.map(results, & &1.status)),
      bodies: frequencies(Enum.map(results, & &1.body)),
      client_durations: Enum.map(results, & &1.duration)
    }
  end

  defp run_websocket_churn(opts, host) do
    port = Process.get(:gatehouse_load_port)
    path = opts.path || "/ws"
    ws_path = if path == "/bench", do: "/ws", else: path
    duration_ms = parse_duration_ms(opts.duration)
    deadline = System.monotonic_time(:millisecond) + duration_ms

    results =
      1..opts.concurrency
      |> Task.async_stream(
        fn index -> websocket_churn_worker(port, host, ws_path, index, deadline) end,
        max_concurrency: opts.concurrency,
        timeout: duration_ms + 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    totals = merge_worker_totals(results)

    %{
      requests: totals.messages,
      concurrency: opts.concurrency,
      duration: opts.duration,
      url: "ws://127.0.0.1:#{port}#{ws_path}",
      host: host,
      statuses: %{
        opened: totals.opened,
        closed: totals.closed,
        echo_ok: totals.echo_ok,
        errors: totals.errors
      },
      bodies: %{},
      client_durations: totals.durations
    }
  end

  defp websocket_churn_worker(port, host, path, index, deadline) do
    churn_every = 10
    message_interval_ms = 100

    initial = %{
      opened: 0,
      closed: 0,
      messages: 0,
      echo_ok: 0,
      errors: 0,
      since_open: 0,
      durations: []
    }

    websocket_churn_loop(
      port,
      host,
      path,
      index,
      deadline,
      churn_every,
      message_interval_ms,
      nil,
      nil,
      initial
    )
  end

  defp websocket_churn_loop(
         port,
         host,
         path,
         index,
         deadline,
         churn_every,
         message_interval_ms,
         conn,
         stream,
         totals
       ) do
    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        totals
        |> close_churn_connection(conn)
        |> Map.update!(:closed, &if(conn, do: &1 + 1, else: &1))

      is_nil(conn) ->
        case open_websocket(port, host, path) do
          {:ok, next_conn, next_stream} ->
            websocket_churn_loop(
              port,
              host,
              path,
              index,
              deadline,
              churn_every,
              message_interval_ms,
              next_conn,
              next_stream,
              %{
                totals
                | opened: totals.opened + 1
              }
            )

          {:error, _reason} ->
            Process.sleep(10)

            websocket_churn_loop(
              port,
              host,
              path,
              index,
              deadline,
              churn_every,
              message_interval_ms,
              nil,
              nil,
              %{totals | errors: totals.errors + 1}
            )
        end

      totals.since_open >= churn_every ->
        totals = close_churn_connection(totals, conn)

        websocket_churn_loop(
          port,
          host,
          path,
          index,
          deadline,
          churn_every,
          message_interval_ms,
          nil,
          nil,
          %{totals | closed: totals.closed + 1, since_open: 0}
        )

      true ->
        message = "ws-churn-#{index}-#{totals.messages + 1}"
        {result, duration} = timed(fn -> websocket_roundtrip(conn, stream, message) end)

        totals =
          case result do
            :ok ->
              %{
                totals
                | messages: totals.messages + 1,
                  echo_ok: totals.echo_ok + 1,
                  since_open: totals.since_open + 1
              }

            {:error, _reason} ->
              %{
                totals
                | messages: totals.messages + 1,
                  errors: totals.errors + 1,
                  since_open: totals.since_open + 1
              }
          end
          |> Map.update!(:durations, &[duration | &1])

        sleep_until_next_message(deadline, message_interval_ms)

        websocket_churn_loop(
          port,
          host,
          path,
          index,
          deadline,
          churn_every,
          message_interval_ms,
          conn,
          stream,
          totals
        )
    end
  end

  defp sleep_until_next_message(deadline, interval_ms) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      Process.sleep(min(interval_ms, remaining_ms))
    end
  end

  defp open_websocket(port, host, path) do
    with {:ok, conn} <- :gun.open(~c"127.0.0.1", port, %{transport: :tcp, protocols: [:http]}),
         {:ok, _protocol} <- :gun.await_up(conn, 5_000),
         stream <- :gun.ws_upgrade(conn, path, [{"host", host}]),
         {:upgrade, _protocols, _headers} <- :gun.await(conn, stream, 5_000) do
      {:ok, conn, stream}
    else
      error -> {:error, error}
    end
  end

  defp websocket_roundtrip(conn, stream, message) do
    with :ok <- :gun.ws_send(conn, stream, {:text, message}),
         {:ws, {:text, ^message}} <- :gun.await(conn, stream, 5_000) do
      :ok
    else
      error -> {:error, error}
    end
  end

  defp close_churn_connection(totals, nil), do: totals

  defp close_churn_connection(totals, conn) do
    :gun.close(conn)
    totals
  end

  defp timed(fun) do
    start = System.monotonic_time()
    result = fun.()
    {result, System.monotonic_time() - start}
  end

  defp merge_worker_totals(results) do
    Enum.reduce(
      results,
      %{opened: 0, closed: 0, messages: 0, echo_ok: 0, errors: 0, since_open: 0, durations: []},
      fn result, acc ->
        %{
          opened: acc.opened + result.opened,
          closed: acc.closed + result.closed,
          messages: acc.messages + result.messages,
          echo_ok: acc.echo_ok + result.echo_ok,
          errors: acc.errors + result.errors,
          since_open: 0,
          durations: result.durations ++ acc.durations
        }
      end
    )
  end

  defp parse_duration_ms(duration) when is_binary(duration) do
    case Regex.run(~r/^([0-9]+)(ms|s|m)?$/, duration) do
      [_match, value, "ms"] -> String.to_integer(value)
      [_match, value, "s"] -> String.to_integer(value) * 1_000
      [_match, value, "m"] -> String.to_integer(value) * 60_000
      [_match, value] -> String.to_integer(value) * 1_000
      _other -> raise "invalid duration #{inspect(duration)}; expected e.g. 500ms, 30s, or 1m"
    end
  end

  defp websocket_echo_once(port, host, path, message) do
    start = System.monotonic_time()

    result =
      with {:ok, conn} <- :gun.open(~c"127.0.0.1", port, %{transport: :tcp, protocols: [:http]}),
           {:ok, _protocol} <- :gun.await_up(conn, 5_000),
           stream <- :gun.ws_upgrade(conn, path, [{"host", host}]),
           {:upgrade, _protocols, _headers} <- :gun.await(conn, stream, 5_000),
           :ok <- :gun.ws_send(conn, stream, {:text, message}),
           {:ws, {:text, ^message}} <- :gun.await(conn, stream, 5_000) do
        :gun.close(conn)
        {:ok, message}
      else
        error -> error
      end

    duration = System.monotonic_time() - start

    case result do
      {:ok, echoed} -> %{status: :ok, body: echoed, duration: duration}
      error -> %{status: {:error, error}, body: inspect(error), duration: duration}
    end
  end

  defp request_once(url, host) do
    start = System.monotonic_time()

    request =
      {String.to_charlist(url),
       [{~c"host", String.to_charlist(host)}, {~c"connection", ~c"close"}]}

    http_opts = [timeout: 15_000, connect_timeout: 5_000]
    opts = [body_format: :binary]
    result = :httpc.request(:get, request, http_opts, opts)
    duration = System.monotonic_time() - start

    case result do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        %{status: status, body: body, duration: duration}

      {:error, reason} ->
        %{status: {:error, reason}, body: "", duration: duration}
    end
  end

  defp print_report(
         result,
         telemetry,
         before_vm,
         after_load_vm,
         settled_vm,
         samples,
         before_processes,
         after_processes,
         opts,
         profile_report
       ) do
    IO.puts("\n== Gatehouse load test ==")
    IO.inspect(Map.drop(result, [:client_durations]), label: "scenario")
    print_duration_summary("client", result.client_durations)

    IO.puts("\n== Gatehouse telemetry ==")

    telemetry
    |> Enum.sort_by(fn {event, _summary} -> event end)
    |> Enum.each(fn {event, summary} ->
      IO.inspect(%{
        event: event,
        count: summary.count,
        statuses: summary.statuses,
        results: summary.results
      })

      print_duration_summary(inspect(event), summary.durations)
    end)

    IO.puts("\n== VM stats ==")

    IO.inspect(%{
      before: before_vm,
      after_load: after_load_vm,
      after_settle: settled_vm,
      load_delta: vm_delta(before_vm, after_load_vm),
      retained_delta: vm_delta(before_vm, settled_vm),
      settle_delta: vm_delta(after_load_vm, settled_vm)
    })

    IO.puts("\n== VM samples ==")
    print_sample_summary(samples)

    if opts.process_diagnostics? do
      IO.puts("\n== Retained process diagnostics ==")
      print_retained_process_diagnostics(before_processes, after_processes)
    end

    if profile_report do
      IO.puts("\n== Profile ==")
      IO.puts(profile_report)
    end
  end

  defp print_duration_summary(label, durations) do
    case duration_summary(durations) do
      nil -> IO.puts("#{label}: no durations")
      summary -> IO.inspect(summary, label: label)
    end
  end

  defp duration_summary([]), do: nil

  defp duration_summary(durations) do
    durations = Enum.sort(durations)

    %{
      count: length(durations),
      p50_ms: percentile_ms(durations, 0.50),
      p95_ms: percentile_ms(durations, 0.95),
      p99_ms: percentile_ms(durations, 0.99),
      max_ms: native_to_ms(List.last(durations))
    }
  end

  defp percentile_ms(sorted, percentile) do
    index = max(0, ceil(length(sorted) * percentile) - 1)
    sorted |> Enum.at(index) |> native_to_ms()
  end

  defp native_to_ms(duration) do
    duration
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
    |> Float.round(3)
  end

  defp start_profile(nil), do: :ok

  defp start_profile("eprof") do
    ensure_tools_on_code_path!()
    {:ok, _pid} = apply(:eprof, :start, [])
    apply(:eprof, :start_profiling, [Process.list()])
  end

  defp start_profile(profile), do: raise("unknown profiler #{inspect(profile)}; expected eprof")

  defp stop_profile(nil), do: nil

  defp stop_profile("eprof") do
    apply(:eprof, :stop_profiling, [])
    apply(:eprof, :analyze, [:total])
    apply(:eprof, :stop, [])
    "eprof results printed above"
  end

  defp ensure_tools_on_code_path! do
    case :code.which(:eprof) do
      :non_existing ->
        tools_ebin =
          :code.lib_dir()
          |> to_string()
          |> Path.join("tools-*/ebin")
          |> Path.wildcard()
          |> List.first()

        unless tools_ebin do
          raise "Erlang tools ebin not found; cannot run eprof"
        end

        true = :code.add_patha(String.to_charlist(tools_ebin))

      _path ->
        :ok
    end
  end

  defp assert_thresholds!(opts, telemetry, before_vm, settled_vm) do
    failures = threshold_failures(opts, telemetry, before_vm, settled_vm)

    if failures != [] do
      IO.puts("\n== Threshold failures ==")
      Enum.each(failures, &IO.puts("- #{&1}"))
      raise "load test threshold failure"
    end
  end

  defp threshold_failures(opts, telemetry, before_vm, settled_vm) do
    []
    |> maybe_check_error_rate(opts.max_error_rate, telemetry)
    |> maybe_check_proxy_p99(opts.max_proxy_p99_ms, telemetry)
    |> maybe_check_retained_total(opts.max_retained_total_mb, before_vm, settled_vm)
    |> maybe_check_retained_processes(opts.max_retained_processes, before_vm, settled_vm)
    |> Enum.reverse()
  end

  defp maybe_check_error_rate(failures, nil, _telemetry), do: failures

  defp maybe_check_error_rate(failures, max_error_rate, telemetry) do
    summary = Map.get(telemetry, [:gatehouse, :proxy, :request, :stop])
    error_rate = proxy_error_rate(summary)

    if error_rate > max_error_rate do
      ["proxy error rate #{Float.round(error_rate, 4)} exceeded #{max_error_rate}" | failures]
    else
      failures
    end
  end

  defp proxy_error_rate(nil), do: 0.0

  defp proxy_error_rate(%{count: 0}), do: 0.0

  defp proxy_error_rate(%{count: count, statuses: statuses}) do
    errors =
      Enum.reduce(statuses, 0, fn
        {status, _status_count}, acc when is_integer(status) and status < 500 ->
          acc

        {_status, status_count}, acc ->
          acc + status_count
      end)

    errors / count
  end

  defp maybe_check_proxy_p99(failures, nil, _telemetry), do: failures

  defp maybe_check_proxy_p99(failures, max_p99_ms, telemetry) do
    summary = Map.get(telemetry, [:gatehouse, :proxy, :request, :stop])
    duration_summary = summary && duration_summary(summary.durations)
    p99_ms = duration_summary && duration_summary.p99_ms

    cond do
      is_nil(p99_ms) ->
        failures

      p99_ms > max_p99_ms ->
        ["proxy p99 #{p99_ms}ms exceeded #{max_p99_ms}ms" | failures]

      true ->
        failures
    end
  end

  defp maybe_check_retained_total(failures, nil, _before_vm, _settled_vm), do: failures

  defp maybe_check_retained_total(failures, max_mb, before_vm, settled_vm) do
    retained_mb = (settled_vm.memory.total - before_vm.memory.total) / 1_048_576

    if retained_mb > max_mb do
      ["retained total memory #{Float.round(retained_mb, 3)}MiB exceeded #{max_mb}MiB" | failures]
    else
      failures
    end
  end

  defp maybe_check_retained_processes(failures, nil, _before_vm, _settled_vm), do: failures

  defp maybe_check_retained_processes(failures, max_processes, before_vm, settled_vm) do
    retained_processes = settled_vm.process_count - before_vm.process_count

    if retained_processes > max_processes do
      ["retained process count #{retained_processes} exceeded #{max_processes}" | failures]
    else
      failures
    end
  end

  defp settle_vm(opts) do
    if opts.gc? do
      force_full_sweep()
    end

    Process.sleep(opts.settle_ms)

    if opts.gc? do
      force_full_sweep()
    end

    vm_stats()
  end

  defp force_full_sweep do
    Process.list()
    |> Enum.each(fn pid ->
      try do
        :erlang.garbage_collect(pid)
      catch
        _class, _reason -> :ok
      end
    end)
  end

  defp process_snapshot do
    Process.list()
    |> Map.new(fn pid -> {pid, process_diagnostic(pid)} end)
  end

  defp process_diagnostic(pid) do
    keys = [
      :registered_name,
      :initial_call,
      :current_function,
      :message_queue_len,
      :memory,
      :links,
      :monitors,
      :monitored_by
    ]

    case Process.info(pid, keys) do
      info when is_list(info) ->
        %{
          pid: inspect(pid),
          name: info[:registered_name],
          initial_call: info[:initial_call],
          current_function: info[:current_function],
          message_queue_len: info[:message_queue_len],
          memory: info[:memory],
          links: length(info[:links] || []),
          monitors: length(info[:monitors] || []),
          monitored_by: length(info[:monitored_by] || [])
        }

      _other ->
        %{pid: inspect(pid), current_function: :dead, memory: 0}
    end
  end

  defp print_retained_process_diagnostics(before, after_processes) do
    before_pids = MapSet.new(Map.keys(before))

    retained =
      after_processes
      |> Enum.reject(fn {pid, _info} -> MapSet.member?(before_pids, pid) end)
      |> Enum.map(fn {_pid, info} -> info end)

    IO.inspect(%{count: length(retained), groups: process_groups(retained)}, limit: 30)

    retained
    |> Enum.sort_by(& &1.memory, :desc)
    |> Enum.take(20)
    |> IO.inspect(label: "largest_retained", limit: 20)
  end

  defp process_groups(processes) do
    processes
    |> Enum.group_by(fn info -> {info.name, info.initial_call, info.current_function} end)
    |> Enum.map(fn {key, members} ->
      {name, initial_call, current_function} = key

      %{
        count: length(members),
        name: name,
        initial_call: initial_call,
        current_function: current_function,
        total_memory: Enum.sum(Enum.map(members, & &1.memory))
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(20)
  end

  defp vm_stats do
    memory = :erlang.memory() |> Map.new()

    %{
      process_count: :erlang.system_info(:process_count),
      memory: memory,
      reductions: elem(:erlang.statistics(:reductions), 0)
    }
  end

  defp vm_delta(before, after_stats) do
    %{
      process_count: after_stats.process_count - before.process_count,
      memory: memory_delta(before.memory, after_stats.memory),
      reductions: after_stats.reductions - before.reductions
    }
  end

  defp memory_delta(before, after_memory) do
    after_memory
    |> Map.keys()
    |> Enum.concat(Map.keys(before))
    |> Enum.uniq()
    |> Map.new(fn key -> {key, Map.get(after_memory, key, 0) - Map.get(before, key, 0)} end)
  end

  defp print_sample_summary([]), do: IO.puts("no samples")

  defp print_sample_summary(samples) do
    total_memory = Enum.map(samples, & &1.memory.total)
    process_counts = Enum.map(samples, & &1.process_count)
    reductions = Enum.map(samples, & &1.reductions)
    first = hd(samples)
    last = List.last(samples)

    IO.inspect(%{
      count: length(samples),
      duration_ms: native_to_ms(last.at_native - first.at_native),
      process_count: %{min: Enum.min(process_counts), max: Enum.max(process_counts)},
      total_memory: %{
        min: Enum.min(total_memory),
        max: Enum.max(total_memory),
        delta: last.memory.total - first.memory.total
      },
      memory_breakdown_delta: memory_delta(first.memory, last.memory),
      reductions_delta: List.last(reductions) - hd(reductions),
      top_processes_last_sample: last.top_processes
    })
  end

  defp frequencies(values), do: Enum.frequencies(values)

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "gatehouse-load-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

Gatehouse.LoadTest.main(System.argv())
