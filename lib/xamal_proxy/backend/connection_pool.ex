defmodule XamalProxy.Backend.ConnectionPool do
  @moduledoc """
  Small Gun connection pool keyed by target origin.

  The pool keeps one Gun connection per `{scheme, host, port}` and reaps idle
  connections periodically.
  """

  use GenServer

  alias XamalProxy.Backend.Connection
  alias XamalProxy.Telemetry

  @sweep_interval 30_000
  @idle_timeout 60_000
  @max_connections 128

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

    case Map.fetch(state, key) do
      {:ok, %{conn: conn} = entry} when is_pid(conn) ->
        if Process.alive?(conn) do
          next_state = Map.put(state, key, %{entry | last_used: now()})
          {:reply, {:ok, conn}, next_state}
        else
          open_and_store(uri, timeout, key, state)
        end

      _missing ->
        open_and_store(uri, timeout, key, state)
    end
  end

  @impl GenServer
  def handle_cast({:invalidate, uri}, state) do
    key = key(uri)

    case Map.pop(state, key) do
      {%{conn: conn}, next_state} when is_pid(conn) ->
        :gun.close(conn)
        Telemetry.execute([:backend, :pool, :invalidate], %{}, %{key: key})
        {:noreply, next_state}

      {_missing, next_state} ->
        {:noreply, next_state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    idle_timeout = Application.get_env(:xamal_proxy, :backend_idle_timeout, @idle_timeout)
    cutoff = now() - idle_timeout

    {expired, active} =
      Enum.split_with(state, fn {_key, %{conn: conn, last_used: last_used}} ->
        last_used < cutoff or not Process.alive?(conn)
      end)

    Enum.each(expired, fn {key, %{conn: conn}} ->
      :gun.close(conn)
      Telemetry.execute([:backend, :pool, :reap], %{}, %{key: key})
    end)

    schedule_sweep()
    {:noreply, Map.new(active)}
  end

  defp open_and_store(uri, timeout, key, state) do
    case Connection.open(uri, timeout) do
      {:ok, conn} ->
        Telemetry.execute([:backend, :pool, :open], %{}, %{key: key})

        next_state =
          state |> maybe_evict_oldest() |> Map.put(key, %{conn: conn, last_used: now()})

        {:reply, {:ok, conn}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_evict_oldest(state) do
    max_connections =
      Application.get_env(:xamal_proxy, :backend_max_connections, @max_connections)

    if map_size(state) < max_connections do
      state
    else
      {key, %{conn: conn}} = Enum.min_by(state, fn {_key, entry} -> entry.last_used end)
      :gun.close(conn)
      Telemetry.execute([:backend, :pool, :evict], %{}, %{key: key})
      Map.delete(state, key)
    end
  end

  defp schedule_sweep do
    Process.send_after(
      self(),
      :sweep,
      Application.get_env(:xamal_proxy, :backend_sweep_interval, @sweep_interval)
    )
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp key(%URI{scheme: scheme, host: host, port: port}) do
    {scheme || "http", host, port || default_port(scheme)}
  end

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
