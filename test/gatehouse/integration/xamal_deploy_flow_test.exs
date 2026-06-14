defmodule Gatehouse.Integration.XamalDeployFlowTest do
  use ExUnit.Case, async: false

  test "simulates Xamal blue-green deploy calls against gatehouse" do
    {:ok, blue} =
      DemoApp.Server.start_link(port: 0, label: "blue", name: unique_name(:xamal_blue))

    {:ok, green} =
      DemoApp.Server.start_link(port: 0, label: "green", name: unique_name(:xamal_green))

    {:ok, listener} =
      Gatehouse.LiveryListener.start_link(port: 0, name: unique_name(:gatehouse))

    proxy_port = listener_port(listener)
    host = "xamal-#{System.unique_integer([:positive])}.test"

    assert {:ok, _state} = xamal_deploy("demo", host, "blue", DemoApp.Server.port(blue))
    assert {:ok, "demo_app:blue\n"} = get(proxy_port, host)

    assert {:ok, _state} = xamal_deploy("demo", host, "green", DemoApp.Server.port(green))
    assert {:ok, "demo_app:green\n"} = get(proxy_port, host)
  end

  defp xamal_deploy(service, host, target_id, port) do
    Gatehouse.Control.deploy(%{
      service: service,
      hosts: [host],
      target_id: target_id,
      target_url: "http://127.0.0.1:#{port}",
      health_path: "/up",
      health_timeout: 1_000,
      drain_timeout: 1_000
    })
  end

  defp get(port, host) do
    url = ~c"http://127.0.0.1:#{port}/"
    headers = [{~c"host", String.to_charlist(host)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp listener_port(pid) do
    case :sys.get_state(pid) do
      %{ports: %{h1: port}} -> port
    end
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end
end
