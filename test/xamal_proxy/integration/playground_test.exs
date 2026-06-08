defmodule XamalProxy.Integration.PlaygroundTest do
  use ExUnit.Case, async: false

  Code.require_file("../../../playground/demo_app/lib/demo_app/server.ex", __DIR__)

  test "prototype listener routes requests to active playground backend and switches on deploy" do
    assert_switches_with(&start_prototype_listener/0)
  end

  test "Livery listener routes requests to active playground backend and switches on deploy" do
    assert_switches_with(&start_livery_listener/0)
  end

  test "Livery listener forwards streamed request and response bodies" do
    {:ok, backend} =
      DemoApp.Server.start_link(port: 0, label: "stream", name: unique_name(:stream))

    {:ok, listener} = start_livery_listener()

    backend_port = DemoApp.Server.port(backend)
    proxy_port = listener_port(listener)
    service = "stream-#{System.unique_integer([:positive])}"
    host = "#{service}.test"

    assert {:ok, _state} =
             XamalProxy.Control.deploy(%{
               service: service,
               hosts: [host],
               target_id: "stream",
               target_url: "http://127.0.0.1:#{backend_port}",
               skip_health_check: true
             })

    assert {:ok, "hello streaming request"} =
             post(proxy_port, host, "/echo", "hello streaming request")

    assert {:ok, "demo_app:stream\n"} = get(proxy_port, host, "/stream")
  end

  defp assert_switches_with(start_listener) do
    {:ok, blue} = DemoApp.Server.start_link(port: 0, label: "blue", name: unique_name(:blue))
    {:ok, green} = DemoApp.Server.start_link(port: 0, label: "green", name: unique_name(:green))
    {:ok, listener} = start_listener.()

    blue_port = DemoApp.Server.port(blue)
    green_port = DemoApp.Server.port(green)
    proxy_port = listener_port(listener)
    service = "playground-#{System.unique_integer([:positive])}"
    host = "#{service}.test"

    assert {:ok, _state} =
             XamalProxy.Control.deploy(%{
               service: service,
               hosts: [host],
               target_id: "blue",
               target_url: "http://127.0.0.1:#{blue_port}",
               skip_health_check: true
             })

    assert {:ok, "demo_app:blue\n"} = get(proxy_port, host)

    assert {:ok, _state} =
             XamalProxy.Control.deploy(%{
               service: service,
               hosts: [host],
               target_id: "green",
               target_url: "http://127.0.0.1:#{green_port}",
               skip_health_check: true
             })

    assert {:ok, "demo_app:green\n"} = get(proxy_port, host)
  end

  defp start_prototype_listener do
    XamalProxy.Listener.start_link(port: 0, name: unique_name(:prototype_listener))
  end

  defp start_livery_listener do
    XamalProxy.LiveryListener.start_link(port: 0, name: unique_name(:livery_listener))
  end

  defp listener_port(pid) do
    case :sys.get_state(pid) do
      %{port: port} -> port
    end
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp get(port, host, path \\ "/") do
    with {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false]),
         :ok <-
           :gen_tcp.send(socket, [
             "GET ",
             path,
             " HTTP/1.1\r\nhost: ",
             host,
             "\r\nconnection: close\r\n\r\n"
           ]),
         {:ok, response} <- recv_all(socket, "") do
      :gen_tcp.close(socket)
      [headers, body] = String.split(response, "\r\n\r\n", parts: 2)
      {:ok, decode_body(headers, body)}
    end
  end

  defp post(port, host, path, body) do
    with {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false]),
         :ok <-
           :gen_tcp.send(socket, [
             "POST ",
             path,
             " HTTP/1.1\r\nhost: ",
             host,
             "\r\ncontent-length: ",
             Integer.to_string(byte_size(body)),
             "\r\nconnection: close\r\n\r\n",
             body
           ]),
         {:ok, response} <- recv_all(socket, "") do
      :gen_tcp.close(socket)
      [headers, response_body] = String.split(response, "\r\n\r\n", parts: 2)
      {:ok, decode_body(headers, response_body)}
    end
  end

  defp decode_body(headers, body) do
    if headers |> String.downcase() |> String.contains?("transfer-encoding: chunked") do
      decode_chunks(body, "")
    else
      body
    end
  end

  defp decode_chunks("0\r\n\r\n", acc), do: acc

  defp decode_chunks(body, acc) do
    [size_hex, rest] = String.split(body, "\r\n", parts: 2)
    size = String.to_integer(size_hex, 16)
    <<chunk::binary-size(^size), "\r\n", tail::binary>> = rest
    decode_chunks(tail, acc <> chunk)
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end
end
