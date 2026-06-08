defmodule XamalProxy.RouteTable do
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
    GenServer.call(__MODULE__, {:put, host, service_id, target_id})
  end

  @spec delete(host()) :: :ok
  def delete(host) do
    GenServer.call(__MODULE__, {:delete, host})
  end

  @spec lookup(host()) :: {:ok, service_id(), target_id()} | :error
  def lookup(host) do
    case :ets.lookup(@table, normalize_host(host)) do
      [{_host, service_id, target_id}] -> {:ok, service_id, target_id}
      [] -> :error
    end
  end

  @spec all() :: [{host(), service_id(), target_id()}]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.sort()
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, host, service_id, target_id}, _from, state) do
    true = :ets.insert(@table, {normalize_host(host), service_id, target_id})
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
