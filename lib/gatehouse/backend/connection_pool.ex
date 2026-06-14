defmodule Gatehouse.Backend.ConnectionPool do
  @moduledoc """
  Small Gun connection pool keyed by target origin.

  The pool keeps a bounded set of Gun connections per `{scheme, host, port}` and
  reaps idle connections periodically. Multiple connections per origin avoid
  forcing all HTTP/1 proxy traffic through a single upstream socket under load.
  """

  use GenServer

  alias Gatehouse.Backend.Connection
  alias Gatehouse.Telemetry

  @sweep_interval 30_000
  @idle_timeout 60_000
  @max_connections 128
  @max_connections_per_origin 32

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec checkout(URI.t(), timeout()) :: {:ok, pid()} | {:error, term()}
  def checkout(%URI{} = uri, timeout) do
    GenServer.call(__MODULE__, {:checkout, uri, timeout}, timeout + 1_000)
  end

  @spec invalidate(URI.t()) :: :ok
  def invalidate(%URI{} = uri) do
    GenServer.cast(__MODULE__, {:invalidate, uri})
  end

  @impl GenServer
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:checkout, uri, timeout}, _from, state) do
    key = key(uri)
    pool = state |> Map.get(key, new_pool()) |> prune_dead_connections()

    cond do
      length(pool.conns) < max_connections_per_origin() ->
        open_and_store(uri, timeout, key, pool, state)

      pool.conns == [] ->
        open_and_store(uri, timeout, key, pool, state)

      true ->
        {entry, next_pool} = checkout_from_pool(pool)
        {:reply, {:ok, entry.conn}, Map.put(state, key, next_pool)}
    end
  end

  @impl GenServer
  def handle_cast({:invalidate, uri}, state) do
    key = key(uri)

    case Map.pop(state, key) do
      {%{conns: conns}, next_state} ->
        Enum.each(conns, &:gun.close(&1.conn))
        Telemetry.execute([:backend, :pool, :invalidate], %{}, %{key: key})
        {:noreply, next_state}

      {_missing, next_state} ->
        {:noreply, next_state}
    end
  end

  @impl GenServer
  def handle_info({:gun_down, conn, _protocol, _reason, _killed_streams}, state) do
    next_state =
      state
      |> Enum.map(fn {key, pool} -> {key, remove_conn(pool, conn)} end)
      |> Enum.reject(fn {_key, pool} -> pool.conns == [] end)
      |> Map.new()

    {:noreply, next_state}
  end

  def handle_info(:sweep, state) do
    idle_timeout = Application.get_env(:gatehouse, :backend_idle_timeout, @idle_timeout)
    cutoff = now() - idle_timeout

    next_state =
      state
      |> Enum.map(fn {key, pool} -> {key, reap_pool(key, pool, cutoff)} end)
      |> Enum.reject(fn {_key, pool} -> pool.conns == [] end)
      |> Map.new()

    schedule_sweep()
    {:noreply, next_state}
  end

  defp open_and_store(uri, timeout, key, pool, state) do
    case Connection.open(uri, timeout) do
      {:ok, conn} ->
        Telemetry.execute([:backend, :pool, :open], %{}, %{key: key})

        entry = %{conn: conn, last_used: now()}
        next_pool = %{pool | conns: [entry | pool.conns]}

        next_state =
          state
          |> Map.put(key, next_pool)
          |> maybe_evict_oldest()

        {:reply, {:ok, conn}, next_state}

      {:error, reason} ->
        next_state =
          if pool.conns == [], do: Map.delete(state, key), else: Map.put(state, key, pool)

        {:reply, {:error, reason}, next_state}
    end
  end

  defp checkout_from_pool(%{conns: conns, next: next} = pool) do
    count = length(conns)
    index = rem(next, count)
    {entry, rest} = List.pop_at(conns, index)
    used_entry = %{entry | last_used: now()}
    next_conns = List.insert_at(rest, index, used_entry)
    {used_entry, %{pool | conns: next_conns, next: rem(index + 1, count)}}
  end

  defp maybe_evict_oldest(state) do
    max_connections = Application.get_env(:gatehouse, :backend_max_connections, @max_connections)

    if total_connections(state) <= max_connections do
      state
    else
      {oldest_key, oldest_entry} =
        state
        |> Enum.flat_map(fn {key, pool} -> Enum.map(pool.conns, &{key, &1}) end)
        |> Enum.min_by(fn {_key, entry} -> entry.last_used end)

      :gun.close(oldest_entry.conn)
      Telemetry.execute([:backend, :pool, :evict], %{}, %{key: oldest_key})
      update_in(state, [oldest_key], &remove_conn(&1, oldest_entry.conn))
    end
  end

  defp reap_pool(key, pool, cutoff) do
    {expired, active} =
      Enum.split_with(pool.conns, fn %{conn: conn, last_used: last_used} ->
        last_used < cutoff or not Process.alive?(conn)
      end)

    Enum.each(expired, fn %{conn: conn} ->
      :gun.close(conn)
      Telemetry.execute([:backend, :pool, :reap], %{}, %{key: key})
    end)

    %{pool | conns: active, next: normalize_next(pool.next, active)}
  end

  defp remove_conn(nil, _conn), do: new_pool()

  defp remove_conn(pool, conn) do
    conns = Enum.reject(pool.conns, &(&1.conn == conn))
    %{pool | conns: conns, next: normalize_next(pool.next, conns)}
  end

  defp prune_dead_connections(pool) do
    conns = Enum.filter(pool.conns, &Process.alive?(&1.conn))
    %{pool | conns: conns, next: normalize_next(pool.next, conns)}
  end

  defp normalize_next(_next, []), do: 0
  defp normalize_next(next, conns), do: rem(next, length(conns))

  defp total_connections(state) do
    state
    |> Map.values()
    |> Enum.reduce(0, fn pool, total -> total + length(pool.conns) end)
  end

  defp max_connections_per_origin do
    Application.get_env(
      :gatehouse,
      :backend_max_connections_per_origin,
      @max_connections_per_origin
    )
  end

  defp new_pool, do: %{conns: [], next: 0}

  defp schedule_sweep do
    Process.send_after(
      self(),
      :sweep,
      Application.get_env(:gatehouse, :backend_sweep_interval, @sweep_interval)
    )
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp key(%URI{scheme: scheme, host: host, port: port}) do
    {scheme || "http", host, port || default_port(scheme)}
  end

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
