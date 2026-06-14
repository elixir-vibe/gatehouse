defmodule Gatehouse.SafeRPC.Pool do
  @moduledoc "Registry-backed SafeRPC client pools for proxy targets."

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def checkout(socket, opts \\ []) when is_binary(socket) do
    GenServer.call(__MODULE__, {:checkout, socket, opts})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:checkout, socket, opts}, _from, state) do
    key = {socket, Keyword.get(opts, :shards, 1), Keyword.get(opts, :cap)}

    case Map.fetch(state, key) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          open_pool(key, socket, opts, Map.delete(state, key))
        end

      _missing ->
        open_pool(key, socket, opts, state)
    end
  end

  defp open_pool(key, socket, opts, state) do
    if File.exists?(socket) do
      start_pool(key, socket, opts, state)
    else
      {:reply, {:error, :enoent}, state}
    end
  end

  defp start_pool(key, socket, opts, state) do
    pool_opts = Keyword.merge(opts, socket: socket, shards: Keyword.get(opts, :shards, 1))

    case SafeRPC.ClientPool.start_link(pool_opts) do
      {:ok, pid} -> {:reply, {:ok, pid}, Map.put(state, key, pid)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end
end
