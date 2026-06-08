defmodule XamalProxy.Restorer do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl GenServer
  def init(_opts) do
    {:ok, nil, {:continue, :restore}}
  end

  @impl GenServer
  def handle_continue(:restore, state) do
    case XamalProxy.Control.restore_if_configured() do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to restore xamal_proxy state: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
