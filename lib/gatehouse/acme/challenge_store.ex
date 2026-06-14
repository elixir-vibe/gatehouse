defmodule Gatehouse.ACME.ChallengeStore do
  @moduledoc """
  In-memory HTTP-01 challenge token store.
  """

  use GenServer

  @name __MODULE__
  @ets_table :gatehouse_acme_challenges

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(domain, token, key_authorization) do
    GenServer.call(@name, {:store_challenge, normalize_domain(domain), token, key_authorization})
  end

  @spec get(String.t(), String.t()) :: {:ok, String.t()} | :error
  def get(domain, token) do
    case :ets.lookup(@ets_table, {normalize_domain(domain), token}) do
      [{{_domain, _token}, key_authorization}] -> {:ok, key_authorization}
      [] -> :error
    end
  end

  @spec delete(String.t(), String.t()) :: :ok
  def delete(domain, token) do
    GenServer.call(@name, {:delete_challenge, normalize_domain(domain), token})
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@ets_table, [:named_table, :public, read_concurrency: true])
    {:ok, :ready}
  end

  @impl GenServer
  def handle_call({:store_challenge, domain, token, key_authorization}, _from, state) do
    true = :ets.insert(@ets_table, {{domain, token}, key_authorization})
    {:reply, :ok, state}
  end

  def handle_call({:delete_challenge, domain, token}, _from, state) do
    true = :ets.delete(@ets_table, {domain, token})
    {:reply, :ok, state}
  end

  defp normalize_domain(domain) do
    domain
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
