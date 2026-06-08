defmodule DemoApp.Server do
  @moduledoc """
  Tiny HTTP server used as a playground backend for `xamal_proxy`.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  @impl GenServer
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    label = Keyword.get(opts, :label, "demo")
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, actual_port} = :inet.port(socket)
    send(self(), :accept)
    {:ok, %{socket: socket, port: actual_port, label: label}}
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl GenServer
  def handle_info(:accept, %{socket: socket, label: label} = state) do
    case :gen_tcp.accept(socket, 1_000) do
      {:ok, client} ->
        Task.start(fn -> respond(client, label) end)

      {:error, :timeout} ->
        :ok

      {:error, reason} ->
        Logger.warning("demo_app accept failed: #{inspect(reason)}")
    end

    send(self(), :accept)
    {:noreply, state}
  end

  defp respond(client, label) do
    body = "demo_app:#{label}\n"

    :gen_tcp.recv(client, 0, 5_000)

    :gen_tcp.send(client, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/plain\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])

    :gen_tcp.close(client)
  end
end
