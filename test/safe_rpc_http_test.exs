defmodule Gatehouse.SafeRPCHTTPTest do
  use ExUnit.Case, async: false

  alias Gatehouse.SafeRPC.HTTP
  alias SafeRPC.Adapter.HTTP.{Request, Response}

  defmodule HTTPService do
    @behaviour SafeRPC.Adapter.Service

    def init(_opts), do: {:ok, %{}}

    def call(:http_request, %Request{path: path}, _meta, _state) do
      {:ok, Response.text(200, "safe rpc #{path}", [{"content-type", "text/plain"}])}
    end
  end

  defmodule HTTPServer do
    use SafeRPC.Adapter.Server, service: HTTPService
  end

  defmodule PlugRouter do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/hello" do
      send_resp(conn, 200, "hello from plug #{conn.host}")
    end
  end

  defmodule PlugRPCServer do
    use SafeRPC.Adapter.Plug, plug: PlugRouter
  end

  test "converts livery requests to SafeRPC HTTP envelopes" do
    request =
      :livery_req.new(%{
        method: "POST",
        scheme: "https",
        authority: "example.com",
        path: "/submit",
        raw_query: "a=1",
        headers: [{"host", "example.com"}, {"content-type", "text/plain"}],
        body: {:buffered, "hello"}
      })

    assert %Request{
             method: "POST",
             scheme: "https",
             host: "example.com",
             port: 443,
             path: "/submit",
             query: "a=1",
             headers: [{"host", "example.com"}, {"content-type", "text/plain"}],
             body: {:full, "hello"}
           } = HTTP.from_livery(request, scheme: :https)
  end

  test "configures SafeRPC targets" do
    socket = socket_path("config")

    config =
      Gatehouse.Config.eval!("""
      import Gatehouse.Config

      service :safe_app do
        host "safe.example.com"
        target :main, safe_rpc: [socket: #{inspect(socket)}, shards: 2], active: true
      end
      """)

    assert :ok = Gatehouse.Control.apply_config(config)
    assert {:ok, "safe_app", "main"} = Gatehouse.RouteTable.lookup("safe.example.com")
    assert {:ok, state} = Gatehouse.Control.get_service("safe_app")
    assert state.active_target.kind == :safe_rpc
    assert state.active_target.socket == socket
    assert state.active_target.shards == 2
  end

  test "forwards livery requests to SafeRPC targets" do
    socket = socket_path("forward")
    {:ok, server} = HTTPServer.start_link(socket: socket)

    config =
      Gatehouse.Config.eval!("""
      import Gatehouse.Config

      service :safe_forward do
        host "forward.example.com"
        target :main, safe_rpc: [socket: #{inspect(socket)}], active: true
      end
      """)

    assert :ok = Gatehouse.Control.apply_config(config)

    request =
      :livery_req.new(%{
        method: "GET",
        scheme: "https",
        authority: "forward.example.com",
        path: "/hello",
        raw_query: "",
        headers: [{"host", "forward.example.com"}],
        body: :empty
      })

    response = Gatehouse.LiveryHandler.handle(request)

    assert Gatehouse.Livery.Response.status(response) == 200
    assert Gatehouse.Livery.Response.body(response) == {:full, "safe rpc /hello"}

    GenServer.stop(server)
  end

  @tag :integration
  test "forwards livery requests through SafeRPC Plug adapters" do
    socket = socket_path("plug")
    {:ok, server} = PlugRPCServer.start_link(socket: socket)

    config =
      Gatehouse.Config.eval!("""
      import Gatehouse.Config

      service :plug_forward do
        host "plug-forward.example.com"
        target :main, safe_rpc: [socket: #{inspect(socket)}], active: true
      end
      """)

    assert :ok = Gatehouse.Control.apply_config(config)

    request =
      :livery_req.new(%{
        method: "GET",
        scheme: "https",
        authority: "plug-forward.example.com",
        path: "/hello",
        raw_query: "",
        headers: [{"host", "plug-forward.example.com"}],
        body: :empty
      })

    response = Gatehouse.LiveryHandler.handle(request)

    assert Gatehouse.Livery.Response.status(response) == 200

    assert Gatehouse.Livery.Response.body(response) ==
             {:full, "hello from plug plug-forward.example.com"}

    GenServer.stop(server)
  end

  test "converts SafeRPC HTTP envelopes to livery responses" do
    response =
      HTTP.to_livery(%Response{
        status: 201,
        headers: [{"x-test", "ok"}],
        body: {:full, "created"}
      })

    assert Gatehouse.Livery.Response.status(response) == 201
    assert Gatehouse.Livery.Response.body(response) == {:full, "created"}
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "xamal-safe-rpc-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
