defmodule XamalProxy.Integration.PlaygroundTest do
  use ExUnit.Case, async: false

  Code.require_file("../../../playground/demo_app/lib/demo_app/server.ex", __DIR__)

  test "routes requests to the active playground backend and switches on deploy" do
    {:ok, blue} = DemoApp.Server.start_link(port: 0, label: "blue", name: :blue_demo_backend)
    {:ok, green} = DemoApp.Server.start_link(port: 0, label: "green", name: :green_demo_backend)
    {:ok, listener} = XamalProxy.Listener.start_link(port: 0, name: :playground_proxy_listener)

    blue_port = DemoApp.Server.port(blue)
    green_port = DemoApp.Server.port(green)
    proxy_port = XamalProxy.Listener.port(listener)

    assert {:ok, _state} =
             XamalProxy.Control.deploy(%{
               service: "playground",
               hosts: ["playground.test"],
               target_id: "blue",
               target_url: "http://127.0.0.1:#{blue_port}",
               skip_health_check: true
             })

    assert {:ok, "demo_app:blue\n"} = get(proxy_port, "playground.test")

    assert {:ok, _state} =
             XamalProxy.Control.deploy(%{
               service: "playground",
               hosts: ["playground.test"],
               target_id: "green",
               target_url: "http://127.0.0.1:#{green_port}",
               skip_health_check: true
             })

    assert {:ok, "demo_app:green\n"} = get(proxy_port, "playground.test")
  end

  defp get(port, host) do
    with {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false]),
         :ok <-
           :gen_tcp.send(socket, [
             "GET / HTTP/1.1\r\nhost: ",
             host,
             "\r\nconnection: close\r\n\r\n"
           ]),
         {:ok, response} <- recv_all(socket, "") do
      :gen_tcp.close(socket)
      [_headers, body] = String.split(response, "\r\n\r\n", parts: 2)
      {:ok, body}
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end
end
