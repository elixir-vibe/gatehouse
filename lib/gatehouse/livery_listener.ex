defmodule Gatehouse.LiveryListener do
  @moduledoc """
  Livery-based HTTP/HTTPS ingress for `gatehouse`.
  """

  use GenServer

  alias Gatehouse.Livery
  alias Gatehouse.LiveryOptions

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    listeners = Keyword.get(opts, :listeners) || listeners_from_opts(opts)
    GenServer.start_link(__MODULE__, listeners, server_opts(name))
  end

  defp server_opts(nil), do: []
  defp server_opts(name), do: [name: name]

  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  def refresh_tls(server \\ __MODULE__) do
    GenServer.call(server, :refresh_tls, :infinity)
  end

  @impl GenServer
  def init(nil) do
    case service_options(nil) do
      %{handler: _handler} = opts when map_size(opts) == 1 -> :ignore
      opts -> start_service(%{listeners: nil, opts: opts})
    end
  end

  def init(listeners) do
    start_service(%{listeners: listeners, opts: service_options(listeners)})
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, Map.get(state.ports, :h1) || Map.get(state.ports, :h2), state}
  end

  def handle_call(:refresh_tls, _from, state) do
    case restart_service(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{service: pid}) when is_pid(pid) do
    Livery.stop_service(pid)
  end

  def terminate(_reason, _state), do: :ok

  defp listeners_from_opts(opts) do
    case Keyword.get(opts, :port) do
      nil -> nil
      port -> [%Gatehouse.Config.Listener{scheme: :http, ip: {0, 0, 0, 0}, port: port}]
    end
  end

  defp service_options(nil), do: LiveryOptions.service_options(&Gatehouse.LiveryHandler.handle/1)

  defp service_options(listeners) do
    listeners
    |> LiveryOptions.from_config_listeners()
    |> Enum.reduce(%{handler: &Gatehouse.LiveryHandler.handle/1}, fn
      %{scheme: :http} = listener, opts ->
        Map.put(opts, :http, Map.delete(listener, :scheme))

      %{scheme: :https} = listener, opts ->
        Map.put(opts, :https, Map.delete(listener, :scheme))

      listener, opts when is_map(listener) ->
        Map.put(opts, listener.scheme, Map.delete(listener, :scheme))
    end)
  end

  defp start_service(%{opts: opts} = state) do
    case Livery.start_service(opts) do
      {:ok, pid} -> {:ok, Map.merge(state, %{service: pid, ports: Livery.listeners(pid)})}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp restart_service(state) do
    old_service = state.service
    old_opts = state.opts
    new_opts = service_options(state.listeners)

    Livery.stop_service(old_service)

    case Livery.start_service(new_opts) do
      {:ok, pid} ->
        {:ok, %{state | service: pid, ports: Livery.listeners(pid), opts: new_opts}}

      {:error, reason} ->
        restore_service(state, old_opts, reason)
    end
  end

  defp restore_service(state, old_opts, reason) do
    case Livery.start_service(old_opts) do
      {:ok, pid} ->
        {:error, reason, %{state | service: pid, ports: Livery.listeners(pid)}}

      {:error, restore_reason} ->
        {:error, {reason, {:restore_failed, restore_reason}}, %{state | service: nil, ports: %{}}}
    end
  end
end
