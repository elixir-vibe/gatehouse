defmodule XamalProxy.Listener do
  @moduledoc """
  Minimal HTTP/1.1 TCP listener prototype.

  This is deliberately small and replaceable. It lets the package exercise the
  request accounting and reverse-proxy path before choosing the final Livery/Gun
  integration.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    port = Keyword.get_lazy(opts, :port, fn -> Application.get_env(:xamal_proxy, :http_port) end)
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
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, actual_port} = :inet.port(socket)
    send(self(), :accept)
    {:ok, %{socket: socket, port: actual_port}}
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl GenServer
  def handle_info(:accept, %{socket: socket} = state) do
    case :gen_tcp.accept(socket, 1_000) do
      {:ok, client} ->
        Task.Supervisor.start_child(XamalProxy.RequestSupervisor, fn ->
          XamalProxy.ReverseProxy.handle(client)
        end)

      {:error, :timeout} ->
        :ok

      {:error, reason} ->
        Logger.warning("xamal_proxy accept failed: #{inspect(reason)}")
    end

    send(self(), :accept)
    {:noreply, state}
  end
end
