defmodule XamalProxy.LiveryListener do
  @moduledoc """
  Livery-based HTTP ingress for `xamal_proxy`.
  """

  use GenServer

  def start_link(opts \\ []) do
    port =
      Keyword.get_lazy(opts, :port, fn -> Application.get_env(:xamal_proxy, :livery_http_port) end)

    name = Keyword.get(opts, :name, __MODULE__)

    case port do
      nil -> :ignore
      port -> GenServer.start_link(__MODULE__, port, name: name)
    end
  end

  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  @impl GenServer
  def init(port) do
    case :livery.start_service(%{
           http: %{port: port},
           handler: &XamalProxy.LiveryHandler.handle/1
         }) do
      {:ok, pid} -> {:ok, %{service: pid, port: h1_port(pid)}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl GenServer
  def terminate(_reason, %{service: pid}) do
    :livery.stop_service(pid)
  end

  def terminate(_reason, _state), do: :ok

  defp h1_port(pid) do
    pid
    |> :livery.which_listeners()
    |> Map.fetch!(:h1)
  end
end
