defmodule XamalProxy.Integration.PlaygroundTest do
  use ExUnit.Case, async: false

  Code.require_file("../../../playground/demo_app/lib/demo_app/server.ex", __DIR__)

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
    url = ~c"http://127.0.0.1:#{port}#{path}"
    headers = [{~c"host", String.to_charlist(host)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> {:ok, body}
      {:ok, {{_version, status, reason}, _headers, body}} -> {:error, {status, reason, body}}
      {:error, reason} -> {:error, reason}
    end
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
