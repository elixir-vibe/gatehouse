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
    case load_static_config() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("failed to load xamal_proxy config: #{inspect(reason)}")
    end

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

  defp load_static_config do
    case Application.get_env(:xamal_proxy, :config_path) do
      nil ->
        :ok

      path ->
        path
        |> XamalProxy.Config.read!()
        |> XamalProxy.Control.apply_config()
    end
  rescue
    exception in [ArgumentError, Code.LoadError, CompileError, File.Error, SyntaxError] ->
      {:error, exception}
  end
end
