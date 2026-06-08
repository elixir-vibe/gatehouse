defmodule XamalProxy.LiveryListener do
  @moduledoc """
  Livery-based HTTP/HTTPS ingress for `xamal_proxy`.
  """

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    listeners = Keyword.get(opts, :listeners) || listeners_from_opts(opts)
    GenServer.start_link(__MODULE__, listeners, name: name)
  end

  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  @impl GenServer
  def init(nil) do
    case XamalProxy.LiveryOptions.service_options(&XamalProxy.LiveryHandler.handle/1) do
      %{handler: _handler} = opts when map_size(opts) == 1 -> :ignore
      opts -> start_service(opts)
    end
  end

  def init(listeners) do
    opts =
      listeners
      |> XamalProxy.LiveryOptions.from_config_listeners()
      |> Enum.reduce(%{handler: &XamalProxy.LiveryHandler.handle/1}, fn
        %{scheme: :http} = listener, opts ->
          Map.put(opts, :http, listener)

        %{scheme: :https} = listener, opts ->
          Map.put(opts, :https, listener)

        listener, opts when is_map(listener) ->
          Map.put(opts, listener.scheme, Map.delete(listener, :scheme))
      end)

    start_service(opts)
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, Map.get(state.ports, :h1) || Map.get(state.ports, :h2), state}
  end

  @impl GenServer
  def terminate(_reason, %{service: pid}) do
    :livery.stop_service(pid)
  end

  def terminate(_reason, _state), do: :ok

  defp listeners_from_opts(opts) do
    case Keyword.get(opts, :port) do
      nil -> nil
      port -> [%XamalProxy.Config.Listener{scheme: :http, ip: {0, 0, 0, 0}, port: port}]
    end
  end

  defp start_service(opts) do
    case :livery.start_service(opts) do
      {:ok, pid} -> {:ok, %{service: pid, ports: :livery.which_listeners(pid)}}
      {:error, reason} -> {:stop, reason}
    end
  end
end
