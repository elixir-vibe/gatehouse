defmodule XamalProxy.Backend.ConnectionPool do
  @moduledoc """
  Small Gun connection pool keyed by target origin.

  The pool keeps one Gun connection per `{scheme, host, port}`. Gun owns request
  multiplexing/pipelining details; callers still receive stream messages in the
  process that started each request.
  """

  use GenServer

  alias XamalProxy.Backend.Connection

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
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:checkout, uri, timeout}, _from, state) do
    key = key(uri)

    case Map.fetch(state, key) do
      {:ok, conn} when is_pid(conn) ->
        if Process.alive?(conn) do
          {:reply, {:ok, conn}, state}
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
      {conn, next_state} when is_pid(conn) ->
        :gun.close(conn)
        {:noreply, next_state}

      {_missing, next_state} ->
        {:noreply, next_state}
    end
  end

  defp open_and_store(uri, timeout, key, state) do
    case Connection.open(uri, timeout) do
      {:ok, conn} -> {:reply, {:ok, conn}, Map.put(state, key, conn)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp key(%URI{scheme: scheme, host: host, port: port}) do
    {scheme || "http", host, port || default_port(scheme)}
  end

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
