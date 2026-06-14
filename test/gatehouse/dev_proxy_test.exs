defmodule Gatehouse.DevProxyTest do
  use ExUnit.Case, async: false

  alias Gatehouse.Dev.{CertStore, Proxy}
  alias Gatehouse.Livery.{Request, Response, WebSocket}

  defmodule CaptureWebSocket do
    @moduledoc false
    @behaviour :ws_handler

    def init(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:websocket_headers, Map.fetch!(request, :headers)})
      {:ok, nil}
    end

    def handle_in({:text, data}, state), do: {:reply, [{:text, data}], state}
    def handle_in(_frame, state), do: {:ok, state}
    def handle_info(_message, state), do: {:ok, state}
    def terminate(_reason, _state), do: :ok
  end

  test "default host is derived from otp app names" do
    assert Proxy.default_host(:my_app) == "my-app.localhost"
    assert Proxy.default_host("admin") == "admin.localhost"
  end

  test "free_port returns a bindable local port" do
    assert {:ok, port} = Proxy.free_port()
    assert is_integer(port)

    assert {:ok, socket} =
             :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    :gen_tcp.close(socket)
  end

  test "cert store creates a reusable local CA and host certificate" do
    cert_dir = tmp_dir("cert-store")

    try do
      assert {:ok, ca} = CertStore.ensure_ca(cert_dir)
      assert File.exists?(ca.cert_path)
      assert File.exists?(ca.key_path)

      assert {:ok, cert} = CertStore.ensure_server_cert("demo.localhost", cert_dir)
      assert File.exists?(cert.cert_path)
      assert File.exists?(cert.key_path)
      assert cert.ca_cert_path == ca.cert_path

      assert [{:Certificate, _der, :not_encrypted}] =
               cert.cert_path
               |> File.read!()
               |> :public_key.pem_decode()
    after
      File.rm_rf!(cert_dir)
    end
  end

  test "proxy exposes an HTTP backend over local HTTPS" do
    cert_dir = tmp_dir("proxy")
    host = "dev-proxy-#{System.unique_integer([:positive])}.localhost"
    service = "dev-proxy-#{System.unique_integer([:positive])}"

    try do
      {:ok, backend} = DemoApp.Server.start_link(port: 0, label: "dev", name: unique_name())

      assert {:ok, proxy} =
               Proxy.start(
                 host: host,
                 service: service,
                 backend_port: DemoApp.Server.port(backend),
                 proxy_port: 0,
                 cert_dir: cert_dir,
                 listener_name: unique_name()
               )

      assert proxy.url =~ ~r/^https:\/\/#{Regex.escape(host)}:/
      assert {host, service, "dev"} in Gatehouse.Control.routes()
      assert {:ok, "demo_app:dev\n"} = https_get(proxy.listener, host, "/")
    after
      File.rm_rf!(cert_dir)
    end
  end

  test "proxy can expose an HTTP backend without TLS" do
    host = "dev-proxy-http-#{System.unique_integer([:positive])}.localhost"
    service = "dev-proxy-http-#{System.unique_integer([:positive])}"

    {:ok, backend} = DemoApp.Server.start_link(port: 0, label: "plain", name: unique_name())

    assert {:ok, proxy} =
             Proxy.start(
               host: host,
               service: service,
               backend_port: DemoApp.Server.port(backend),
               proxy_port: 0,
               tls: false,
               listener_name: unique_name()
             )

    assert proxy.url =~ ~r/^http:\/\/#{Regex.escape(host)}:/
    assert {:ok, "demo_app:plain\n"} = http_get(proxy.listener, host, "/")
  end

  test "proxy exposes a websocket backend over local HTTPS" do
    cert_dir = tmp_dir("proxy-ws")
    host = "dev-proxy-wss-#{System.unique_integer([:positive])}.localhost"
    service = "dev-proxy-wss-#{System.unique_integer([:positive])}"

    {:ok, backend} = start_header_capture_backend(self())

    try do
      assert {:ok, proxy} =
               Proxy.start(
                 host: host,
                 service: service,
                 backend_port: livery_port(backend),
                 proxy_port: 0,
                 cert_dir: cert_dir,
                 listener_name: unique_name()
               )

      assert {:ok, "hello-https"} =
               websocket_echo(proxy.listener, host, "/ws", "hello-https", tls: true)
    after
      :ok = Gatehouse.Livery.stop_service(backend)
      File.rm_rf!(cert_dir)
    end
  end

  test "websocket proxy does not forward browser handshake headers to the backend upgrade" do
    host = "dev-proxy-ws-#{System.unique_integer([:positive])}.localhost"
    service = "dev-proxy-ws-#{System.unique_integer([:positive])}"

    {:ok, backend} = start_header_capture_backend(self())

    try do
      assert {:ok, proxy} =
               Proxy.start(
                 host: host,
                 service: service,
                 backend_port: livery_port(backend),
                 proxy_port: 0,
                 tls: false,
                 listener_name: unique_name()
               )

      assert {:ok, "hello"} = websocket_echo(proxy.listener, host, "/ws", "hello")
      assert_receive {:websocket_headers, headers}, 1_000

      refute Enum.any?(headers, fn {name, value} ->
               String.downcase(to_string(name)) == "sec-websocket-protocol" and
                 value == "gatehouse-test"
             end)
    after
      :ok = Gatehouse.Livery.stop_service(backend)
    end
  end

  defp start_header_capture_backend(parent) do
    Gatehouse.Livery.start_service(%{
      http: %{port: 0},
      handler: fn request ->
        case Request.path(request) do
          "/ws" -> WebSocket.upgrade(request, CaptureWebSocket, parent: parent)
          _path -> Response.text(404, "not found")
        end
      end
    })
  end

  defp livery_port(service) do
    service
    |> Gatehouse.Livery.listeners()
    |> Map.fetch!(:h1)
  end

  defp websocket_echo(listener, host, path, message, opts \\ []) do
    port = Gatehouse.LiveryListener.port(listener)

    with {:ok, conn} <- :gun.open(~c"127.0.0.1", port, gun_opts(host, opts)),
         {:ok, _protocol} <- :gun.await_up(conn, 5_000) do
      stream =
        :gun.ws_upgrade(conn, path, [
          {"host", host},
          {"sec-websocket-protocol", "gatehouse-test"}
        ])

      result = await_websocket_echo(conn, stream, message)

      :gun.close(conn)
      result
    end
  end

  defp gun_opts(host, opts) do
    if Keyword.get(opts, :tls, false) do
      %{
        transport: :tls,
        protocols: [:http],
        tls_opts: [verify: :verify_none, server_name_indication: String.to_charlist(host)]
      }
    else
      %{transport: :tcp, protocols: [:http]}
    end
  end

  defp await_websocket_echo(conn, stream, message) do
    case :gun.await(conn, stream, 5_000) do
      {:upgrade, _protocols, _headers} ->
        :gun.ws_send(conn, stream, {:text, message})

        case :gun.await(conn, stream, 5_000) do
          {:ws, {:text, echoed}} -> {:ok, echoed}
          other -> {:error, other}
        end

      other ->
        {:error, other}
    end
  end

  defp https_get(listener, host, path) do
    port = Gatehouse.LiveryListener.port(listener)
    url = ~c"https://127.0.0.1:#{port}#{path}"
    headers = [{~c"host", String.to_charlist(host)}]
    http_opts = [ssl: [verify: :verify_none, server_name_indication: String.to_charlist(host)]]

    case :httpc.request(:get, {url, headers}, http_opts, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> {:ok, body}
      {:ok, {{_version, status, reason}, _headers, body}} -> {:error, {status, reason, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_get(listener, host, path) do
    port = Gatehouse.LiveryListener.port(listener)
    url = ~c"http://127.0.0.1:#{port}#{path}"
    headers = [{~c"host", String.to_charlist(host)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> {:ok, body}
      {:ok, {{_version, status, reason}, _headers, body}} -> {:error, {status, reason, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tmp_dir(prefix) do
    Path.join(System.tmp_dir!(), "gatehouse-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp unique_name do
    String.to_atom("gatehouse_dev_proxy_test_#{System.unique_integer([:positive])}")
  end
end
