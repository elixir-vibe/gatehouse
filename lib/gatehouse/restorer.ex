defmodule Gatehouse.Restorer do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl GenServer
  def init(_opts) do
    case load_static_config() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("failed to load gatehouse config: #{inspect(reason)}")
    end

    case Gatehouse.Control.restore_if_configured() do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to restore gatehouse state: #{inspect(reason)}")
    end

    {:ok, nil}
  end

  defp load_static_config do
    case Application.get_env(:gatehouse, :config_path) do
      nil ->
        :ok

      path ->
        config = Gatehouse.Config.read!(path)

        Application.put_env(
          :gatehouse,
          :listeners,
          Gatehouse.LiveryOptions.from_config(config)
        )

        Application.put_env(:gatehouse, :acme_certificates, Gatehouse.ACME.Config.jobs(config))

        Gatehouse.Control.apply_config(config)
    end
  rescue
    exception in [ArgumentError, Code.LoadError, CompileError, File.Error, SyntaxError] ->
      {:error, exception}
  end
end
