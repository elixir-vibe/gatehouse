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
    Map.update!(summary, :durations, &[duration | &1])
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

defmodule Gatehouse.LoadTest.HTTPBackend do
  alias Gatehouse.Livery
  alias Gatehouse.Livery.{Request, Response}

  def start_link(label) do
    handler = fn request -> Response.text(200, "#{label} #{Request.path(request)}") end

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
  alias Gatehouse.LoadTest.{HTTPBackend, SafeRPCServer, TelemetryCollector, VMSampler}

  def main(argv) do
    opts = parse_args(argv)
    ensure_started!()
    {:ok, _collector} = TelemetryCollector.start_link([])
    TelemetryCollector.attach()

    {:ok, _sampler} = VMSampler.start_link(interval: opts.sample_interval)
    before_vm = vm_stats()

    try do
      result = run(opts)
      after_load_vm = vm_stats()
      settled_vm = settle_vm(opts)
      samples = VMSampler.stop()

      print_report(
        result,
        TelemetryCollector.snapshot(),
        before_vm,
        after_load_vm,
        settled_vm,
        samples
      )
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
          rate: :string
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
      rate: Keyword.get(opts, :rate, "1000/s")
    }
  end

  defp ensure_started! do
    {:ok, _} = Application.ensure_all_started(:gatehouse)
    {:ok, _} = Application.ensure_all_started(:req)
  end

  defp run(%{scenario: "http_baseline"} = opts), do: http_baseline(opts)
  defp run(%{scenario: "safe_rpc_baseline"} = opts), do: safe_rpc_baseline(opts)
  defp run(%{scenario: "safe_rpc_blue_green"} = opts), do: safe_rpc_blue_green(opts)
  defp run(%{scenario: "safe_rpc_failure"} = opts), do: safe_rpc_failure(opts)
  defp run(%{scenario: scenario}), do: raise("unknown scenario: #{scenario}")

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

  defp request_once(url, host) do
    start = System.monotonic_time()

    result =
      Req.get(url,
        headers: [{"host", host}],
        retry: false,
        receive_timeout: 15_000
      )

    duration = System.monotonic_time() - start

    case result do
      {:ok, response} -> %{status: response.status, body: response.body, duration: duration}
      {:error, reason} -> %{status: {:error, reason}, body: "", duration: duration}
    end
  end

  defp print_report(result, telemetry, before_vm, after_load_vm, settled_vm, samples) do
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
  end

  defp print_duration_summary(label, durations) do
    durations = Enum.sort(durations)

    if durations == [] do
      IO.puts("#{label}: no durations")
    else
      IO.inspect(
        %{
          count: length(durations),
          p50_ms: percentile_ms(durations, 0.50),
          p95_ms: percentile_ms(durations, 0.95),
          p99_ms: percentile_ms(durations, 0.99),
          max_ms: native_to_ms(List.last(durations))
        },
        label: label
      )
    end
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
