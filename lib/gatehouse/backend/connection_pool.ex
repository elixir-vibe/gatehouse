defmodule Gatehouse.Backend.ConnectionPool do
  @moduledoc """
  Small Gun connection pool keyed by target origin.

  The pool keeps a bounded set of Gun connections per `{scheme, host, port}` and
  reaps idle connections periodically. Multiple connections per origin avoid
  forcing all HTTP/1 proxy traffic through a single upstream socket under load.

  Checkout is intentionally read-hot: it does not scan the per-origin pool or
  call `Process.alive?/1` for every request. Dead connections are removed from
  async `:gun_down` messages and the periodic idle sweep; request failures still
  invalidate the origin pool from the caller side.
  """

  use GenServer

  alias Gatehouse.Backend.Connection
  alias Gatehouse.Telemetry

  defmodule Pool do
    @moduledoc false
    defstruct conns: {}, size: 0, next: 0
  end

  @sweep_interval 30_000
  @idle_timeout 60_000
  @max_connections 128
  @max_connections_per_origin 32

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{pools: %{}, total: 0}, name: __MODULE__)
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
    pool = Map.get(state.pools, key, new_pool())

    if pool.size < max_connections_per_origin() do
      open_and_store(uri, timeout, key, pool, state)
    else
      {entry, next_pool} = checkout_from_pool(pool)
      {:reply, {:ok, entry.conn}, put_pool(state, key, next_pool)}
    end
  end

  @impl GenServer
  def handle_cast({:invalidate, uri}, state) do
    key = key(uri)

    case Map.pop(state.pools, key) do
      {%{conns: conns, size: size}, pools} ->
        conns
        |> Tuple.to_list()
        |> Enum.each(&:gun.close(&1.conn))

        Telemetry.execute([:backend, :pool, :invalidate], %{}, %{key: key})
        {:noreply, %{state | pools: pools, total: state.total - size}}

      {_missing, pools} ->
        {:noreply, %{state | pools: pools}}
    end
  end

  @impl GenServer
  def handle_info({:gun_down, conn, _protocol, _reason, _killed_streams}, state) do
    {:noreply, remove_conn_from_state(state, conn)}
  end

  def handle_info(:sweep, state) do
    idle_timeout = Application.get_env(:gatehouse, :backend_idle_timeout, @idle_timeout)
    cutoff = now() - idle_timeout

    next_state =
      Enum.reduce(state.pools, %{state | pools: %{}, total: 0}, fn {key, pool}, acc ->
        {active_pool, expired} = reap_pool(pool, cutoff)

        Enum.each(expired, fn %{conn: conn} ->
          :gun.close(conn)
          Telemetry.execute([:backend, :pool, :reap], %{}, %{key: key})
        end)

        if active_pool.size == 0 do
          acc
        else
          put_pool(%{acc | total: acc.total + active_pool.size}, key, active_pool)
        end
      end)

    schedule_sweep()
    {:noreply, next_state}
  end

  defp open_and_store(uri, timeout, key, pool, state) do
    case Connection.open(uri, timeout) do
      {:ok, conn} ->
        Telemetry.execute([:backend, :pool, :open], %{}, %{key: key})

        entry = %{conn: conn, last_used: now()}
        next_pool = append_conn(pool, entry)

        next_state =
          state
          |> put_pool(key, next_pool)
          |> Map.update!(:total, &(&1 + 1))
          |> maybe_evict_oldest()

        {:reply, {:ok, conn}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp checkout_from_pool(%{conns: conns, next: next, size: size} = pool) when size > 0 do
    index = rem(next, size)
    entry = elem(conns, index)
    used_entry = %{entry | last_used: now()}
    next_conns = put_elem(conns, index, used_entry)
    {used_entry, %{pool | conns: next_conns, next: rem(index + 1, size)}}
  end

  defp append_conn(pool, entry) do
    %{pool | conns: Tuple.insert_at(pool.conns, pool.size, entry), size: pool.size + 1}
  end

  defp put_pool(state, key, pool) do
    %{state | pools: Map.put(state.pools, key, pool)}
  end

  defp maybe_evict_oldest(state) do
    max_connections = Application.get_env(:gatehouse, :backend_max_connections, @max_connections)

    if state.total <= max_connections do
      state
    else
      {oldest_key, oldest_entry} =
        state.pools
        |> Enum.flat_map(fn {key, pool} ->
          pool.conns
          |> Tuple.to_list()
          |> Enum.map(&{key, &1})
        end)
        |> Enum.min_by(fn {_key, entry} -> entry.last_used end)

      :gun.close(oldest_entry.conn)
      Telemetry.execute([:backend, :pool, :evict], %{}, %{key: oldest_key})
      remove_conn_from_state(state, oldest_entry.conn)
    end
  end

  defp reap_pool(pool, cutoff) do
    {expired, active} =
      pool.conns
      |> Tuple.to_list()
      |> Enum.split_with(fn %{conn: conn, last_used: last_used} ->
        last_used < cutoff or not Process.alive?(conn)
      end)

    {pool_from_list(active, pool.next), expired}
  end

  defp remove_conn_from_state(state, conn) do
    Enum.reduce(state.pools, %{state | pools: %{}, total: 0}, fn {key, pool}, acc ->
      next_pool = remove_conn(pool, conn)

      if next_pool.size == 0 do
        acc
      else
        put_pool(%{acc | total: acc.total + next_pool.size}, key, next_pool)
      end
    end)
  end

  defp remove_conn(pool, conn) do
    pool.conns
    |> Tuple.to_list()
    |> Enum.reject(&(&1.conn == conn))
    |> pool_from_list(pool.next)
  end

  defp pool_from_list(conns, next) do
    size = length(conns)
    %Pool{conns: List.to_tuple(conns), size: size, next: normalize_next(next, size)}
  end

  defp normalize_next(_next, 0), do: 0
  defp normalize_next(next, size), do: rem(next, size)

  defp max_connections_per_origin do
    Application.get_env(
      :gatehouse,
      :backend_max_connections_per_origin,
      @max_connections_per_origin
    )
  end

  defp new_pool, do: %Pool{}

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
