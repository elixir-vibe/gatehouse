defmodule Gatehouse.SafeRPC.Pool do
  @moduledoc "Registry-backed SafeRPC client pools for proxy targets."

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def checkout(socket, opts \\ []) when is_binary(socket) do
    GenServer.call(__MODULE__, {:checkout, socket, opts})
  end

  def invalidate(socket, opts \\ []) when is_binary(socket) do
    GenServer.call(__MODULE__, {:invalidate, socket, opts})
  end

  @impl true
  def init(_state), do: {:ok, %{pools: %{}, refs: %{}}}

  @impl true
  def handle_call({:checkout, socket, opts}, _from, state) do
    key = {socket, Keyword.get(opts, :shards, 1), Keyword.get(opts, :cap)}

    case Map.fetch(state.pools, key) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          open_pool(key, socket, opts, remove_pool(state, key))
        end

      _missing ->
        open_pool(key, socket, opts, state)
    end
  end

  def handle_call({:invalidate, socket, opts}, _from, state) do
    key = {socket, Keyword.get(opts, :shards, 1), Keyword.get(opts, :cap)}
    {:reply, :ok, stop_and_remove_pool(state, key)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {key, refs} ->
        {:noreply, %{state | refs: refs, pools: Map.delete(state.pools, key)}}
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

    child_spec =
      Supervisor.child_spec({SafeRPC.ClientPool, pool_opts},
        id: {SafeRPC.ClientPool, key},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(Gatehouse.SafeRPC.PoolSupervisor, child_spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        state = put_pool(state, key, pid, ref)
        {:reply, {:ok, pid}, state}

      {:ok, pid, _info} ->
        ref = Process.monitor(pid)
        state = put_pool(state, key, pid, ref)
        {:reply, {:ok, pid}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp put_pool(state, key, pid, ref) do
    %{state | pools: Map.put(state.pools, key, pid), refs: Map.put(state.refs, ref, key)}
  end

  defp remove_pool(state, key) do
    %{state | pools: Map.delete(state.pools, key)}
  end

  defp stop_and_remove_pool(state, key) do
    case Map.fetch(state.pools, key) do
      {:ok, pid} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Gatehouse.SafeRPC.PoolSupervisor, pid)

      _missing ->
        :ok
    end

    remove_pool(state, key)
  end
end
