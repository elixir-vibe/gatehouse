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
    case read_request(client) do
      {:ok, %{path: "/up"}} -> send_plain(client, "ok\n")
      {:ok, %{path: "/echo", body: body}} -> send_plain(client, body)
      {:ok, %{path: "/stream"}} -> send_chunked(client, ["demo_", "app:", label, "\n"])
      {:ok, _request} -> send_plain(client, "demo_app:#{label}\n")
      {:error, _reason} -> :ok
    end

    :gen_tcp.close(client)
  end

  defp read_request(client) do
    with {:ok, data} <- :gen_tcp.recv(client, 0, 5_000) do
      parse_request(client, data)
    end
  end

  defp parse_request(client, data) do
    [head | body_parts] = String.split(data, "\r\n\r\n", parts: 2)
    [request_line | headers] = String.split(head, "\r\n")
    [_method, path, _version] = String.split(request_line, " ", parts: 3)
    body = read_body(client, headers, Enum.join(body_parts, "\r\n\r\n"))
    {:ok, %{path: path, body: body}}
  end

  defp read_body(client, headers, body) do
    content_length = content_length(headers)
    missing = content_length - byte_size(body)

    if missing > 0 do
      {:ok, rest} = :gen_tcp.recv(client, missing, 5_000)
      body <> rest
    else
      body
    end
  end

  defp content_length(headers) do
    headers
    |> Enum.find_value("0", fn header ->
      case String.split(header, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length", do: String.trim(value)

        _other ->
          nil
      end
    end)
    |> String.to_integer()
  end

  defp send_plain(client, body) do
    :gen_tcp.send(client, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/plain\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])
  end

  defp send_chunked(client, chunks) do
    encoded_chunks = Enum.map(chunks, &[Integer.to_string(byte_size(&1), 16), "\r\n", &1, "\r\n"])

    :gen_tcp.send(client, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/plain\r\n",
      "transfer-encoding: chunked\r\n",
      "connection: close\r\n",
      "\r\n",
      encoded_chunks,
      "0\r\n\r\n"
    ])
  end
end
