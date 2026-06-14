defmodule Gatehouse.RouteTable do
  @moduledoc """
  Fast, supervised ETS route table.

  Deploy coordination happens in service processes; the request path should only
  do an ETS lookup by host and receive the currently active target.
  """

  use GenServer

  @table __MODULE__

  @type host :: String.t()
  @type service_id :: String.t()
  @type target_id :: String.t() | :select

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec put(host(), service_id(), target_id()) :: :ok
  def put(host, service_id, target_id) do
    put(host, service_id, target_id, nil)
  end

  @spec put(host(), service_id(), target_id(), term()) :: :ok
  def put(host, service_id, target_id, target_data) do
    GenServer.call(__MODULE__, {:put, host, service_id, target_id, target_data})
  end

  @spec delete(host()) :: :ok
  def delete(host) do
    GenServer.call(__MODULE__, {:delete, host})
  end

  @spec lookup(host()) :: {:ok, service_id(), target_id()} | :error
  def lookup(host) do
    case :ets.lookup(@table, normalize_host(host)) do
      [{_host, service_id, target_id, _target_data, _cursor}] -> {:ok, service_id, target_id}
      [] -> :error
    end
  end

  @spec lookup_target(host()) :: {:ok, service_id(), target_id(), term()} | :error
  def lookup_target(host) do
    key = normalize_host(host)

    case :ets.lookup(@table, key) do
      [{_host, service_id, :select, targets, cursor}]
      when is_tuple(targets) and tuple_size(targets) > 0 ->
        index = rem(cursor, tuple_size(targets))
        :ets.update_counter(@table, key, {5, 1})
        target = elem(targets, index)
        {:ok, service_id, target.id, target}

      [{_host, service_id, target_id, target, _cursor}] when not is_nil(target) ->
        {:ok, service_id, target_id, target}

      [{_host, service_id, target_id, _target_data, _cursor}] ->
        {:ok, service_id, target_id, nil}

      [] ->
        :error
    end
  end

  @spec all() :: [{host(), service_id(), target_id()}]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {host, service_id, target_id, _target_data, _cursor} ->
      {host, service_id, target_id}
    end)
    |> Enum.sort()
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, host, service_id, target_id, target_data}, _from, state) do
    true = :ets.insert(@table, {normalize_host(host), service_id, target_id, target_data, 0})
    {:reply, :ok, state}
  end

  def handle_call({:delete, host}, _from, state) do
    true = :ets.delete(@table, normalize_host(host))
    {:reply, :ok, state}
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
  end
end
