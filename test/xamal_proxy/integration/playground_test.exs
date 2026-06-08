defmodule XamalProxy.Integration.PlaygroundTest do
  use ExUnit.Case, async: false

  alias XamalProxy.Acme.ChallengeStore

  Code.require_file("../../../playground/demo_app/lib/demo_app/websocket_echo.ex", __DIR__)
  Code.require_file("../../../playground/demo_app/lib/demo_app/server.ex", __DIR__)

  test "Livery listener serves HTTP-01 challenges before proxy routing" do
    {:ok, listener} = start_livery_listener()
    proxy_port = listener_port(listener)
    host = "acme-#{System.unique_integer([:positive])}.test"

    assert :ok = ChallengeStore.put(host, "token", "key-auth")
    assert {:ok, "key-auth"} = get(proxy_port, host, "/.well-known/acme-challenge/token")
  end

  test "Livery listener routes requests to active playground backend and switches on deploy" do
    {:ok, blue} = DemoApp.Server.start_link(port: 0, label: "blue", name: unique_name(:blue))
    {:ok, green} = DemoApp.Server.start_link(port: 0, label: "green", name: unique_name(:green))
    {:ok, listener} = start_livery_listener()

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

  test "round robin config balances across active targets" do
    {:ok, blue} = DemoApp.Server.start_link(port: 0, label: "blue", name: unique_name(:rr_blue))

    {:ok, green} =
      DemoApp.Server.start_link(port: 0, label: "green", name: unique_name(:rr_green))

    {:ok, listener} = start_livery_listener()

    proxy_port = listener_port(listener)
    service = "rr-#{System.unique_integer([:positive])}"
    host = "#{service}.test"

    config = %XamalProxy.Config{
      services: [
        %XamalProxy.Config.Service{
          name: service,
          hosts: [host],
          balance: %{policy: :round_robin, options: []},
          targets: [
            %XamalProxy.Config.Target{
              name: "blue",
              url: "http://127.0.0.1:#{DemoApp.Server.port(blue)}",
              active?: true
            },
            %XamalProxy.Config.Target{
              name: "green",
              url: "http://127.0.0.1:#{DemoApp.Server.port(green)}",
              active?: true
            }
          ]
        }
      ]
    }

    assert :ok = XamalProxy.Control.apply_config(config)
    assert {:ok, "demo_app:blue\n"} = get(proxy_port, host)
    assert {:ok, "demo_app:green\n"} = get(proxy_port, host)
    assert {:ok, "demo_app:blue\n"} = get(proxy_port, host)
  end

  test "Livery listener forwards request and streamed response bodies" do
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

    assert {:ok, "hello request"} = post(proxy_port, host, "/echo", "hello request")
    assert {:ok, "demo_app:stream\n"} = get(proxy_port, host, "/stream")
  end

  test "Livery listener proxies WebSocket frames" do
    {:ok, backend} = DemoApp.Server.start_link(port: 0, label: "ws", name: unique_name(:ws))
    {:ok, listener} = start_livery_listener()

    backend_port = DemoApp.Server.port(backend)
    proxy_port = listener_port(listener)
    service = "ws-#{System.unique_integer([:positive])}"
    host = "#{service}.test"

    assert {:ok, _state} =
             XamalProxy.Control.deploy(%{
               service: service,
               hosts: [host],
               target_id: "ws",
               target_url: "http://127.0.0.1:#{backend_port}",
               skip_health_check: true
             })

    assert {:ok, "hello-ws"} = websocket_echo(proxy_port, host, "/ws", "hello-ws")
  end

  test "drain keeps old target while streamed proxied request is active" do
    {:ok, blue} =
      DemoApp.Server.start_link(port: 0, label: "blue", name: unique_name(:drain_blue))

    {:ok, green} =
      DemoApp.Server.start_link(port: 0, label: "green", name: unique_name(:drain_green))

    {:ok, listener} = start_livery_listener()

    proxy_port = listener_port(listener)
    service = "drain-#{System.unique_integer([:positive])}"
    host = "#{service}.test"

    assert {:ok, _state} =
             XamalProxy.Control.deploy(%{
               service: service,
               hosts: [host],
               target_id: "blue",
               target_url: "http://127.0.0.1:#{DemoApp.Server.port(blue)}",
               skip_health_check: true
             })

    task = Task.async(fn -> get(proxy_port, host, "/slow") end)
    Process.sleep(50)

    assert {:ok, state} =
             XamalProxy.Control.deploy(%{
               service: service,
               hosts: [host],
               target_id: "green",
               target_url: "http://127.0.0.1:#{DemoApp.Server.port(green)}",
               skip_health_check: true
             })

    assert Map.has_key?(state.old_targets, "blue")
    assert {:ok, "start-blue\n"} = Task.await(task, 1_000)

    assert eventually(fn ->
             {:ok, state} = XamalProxy.Control.get_service(service)
             refute Map.has_key?(state.old_targets, "blue")
           end)
  end

  defp start_livery_listener do
    XamalProxy.LiveryListener.start_link(port: 0, name: unique_name(:livery_listener))
  end

  defp listener_port(pid) do
    case :sys.get_state(pid) do
      %{port: port} -> port
      %{ports: %{h1: port}} -> port
    end
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp get(port, host, path \\ "/") do
    url = ~c"http://127.0.0.1:#{port}#{path}"
    headers = [{~c"host", String.to_charlist(host)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> {:ok, body}
      {:ok, {{_version, status, reason}, _headers, body}} -> {:error, {status, reason, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp websocket_echo(port, host, path, message) do
    with {:ok, conn} <- :gun.open(~c"127.0.0.1", port, %{transport: :tcp, protocols: [:http]}),
         {:ok, _protocol} <- :gun.await_up(conn, 5_000) do
      stream = :gun.ws_upgrade(conn, path, [{"host", host}])

      result = await_websocket_echo(conn, stream, message)

      :gun.close(conn)
      result
    end
  end

  defp await_websocket_echo(conn, stream, message) do
    case :gun.await(conn, stream, 5_000) do
      {:upgrade, _protocols, _headers} -> send_websocket_echo(conn, stream, message)
      other -> {:error, other}
    end
  end

  defp send_websocket_echo(conn, stream, message) do
    :gun.ws_send(conn, stream, {:text, message})

    case :gun.await(conn, stream, 5_000) do
      {:ws, {:text, echoed}} -> {:ok, echoed}
      other -> {:error, other}
    end
  end

  defp eventually(assertion, attempts \\ 20)

  defp eventually(assertion, attempts) when attempts > 0 do
    assertion.()
    true
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end

  defp post(port, host, path, body) do
    url = ~c"http://127.0.0.1:#{port}#{path}"
    headers = [{~c"host", String.to_charlist(host)}]

    case :httpc.request(:post, {url, headers, ~c"text/plain", body}, [], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, response_body}} ->
        {:ok, response_body}

      {:ok, {{_version, status, reason}, _headers, response_body}} ->
        {:error, {status, reason, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
