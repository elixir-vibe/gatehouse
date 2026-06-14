defmodule Gatehouse.SafeRPCHTTPTest do
  use ExUnit.Case, async: false

  alias Gatehouse.SafeRPC.HTTP
  alias Gatehouse.SafeRPC.Pool, as: SafeRPCPool
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

  test "recreates supervised SafeRPC client pools after a crash" do
    socket = socket_path("supervised")
    File.rm(socket)
    {:ok, server} = HTTPServer.start_link(socket: socket)

    assert {:ok, pool} = SafeRPCPool.checkout(socket, shards: 1)
    ref = Process.monitor(pool)
    Process.exit(pool, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pool, :killed}

    eventually(fn ->
      assert {:ok, replacement} = SafeRPCPool.checkout(socket, shards: 1)
      assert replacement != pool
      assert Process.alive?(replacement)
    end)

    GenServer.stop(server)
  end

  test "returns gateway error when SafeRPC socket is missing" do
    socket = socket_path("missing")
    File.rm(socket)

    config =
      Gatehouse.Config.eval!("""
      import Gatehouse.Config

      service :safe_missing do
        host "safe-missing.example.com"
        target :main, safe_rpc: [socket: #{inspect(socket)}], active: true
      end
      """)

    assert :ok = Gatehouse.Control.apply_config(config)

    request =
      :livery_req.new(%{
        method: "GET",
        scheme: "https",
        authority: "safe-missing.example.com",
        path: "/hello",
        raw_query: "",
        headers: [{"host", "safe-missing.example.com"}],
        body: :empty
      })

    response = Gatehouse.LiveryHandler.handle(request)

    assert Gatehouse.Livery.Response.status(response) == 502
    assert Gatehouse.Livery.Response.body(response) == {:full, "bad gateway: :enoent"}
  end

  test "emits SafeRPC telemetry when forwarding requests" do
    test_pid = self()
    ref = make_ref()
    handler_id = "gatehouse-safe-rpc-telemetry"
    socket = socket_path("telemetry")

    :telemetry.detach(handler_id)
    {:ok, server} = HTTPServer.start_link(socket: socket)

    :telemetry.attach_many(
      handler_id,
      [
        [:gatehouse, :safe_rpc, :pool, :checkout, :stop],
        [:gatehouse, :safe_rpc, :request, :stop]
      ],
      &__MODULE__.handle_event/4,
      {test_pid, ref}
    )

    config =
      Gatehouse.Config.eval!("""
      import Gatehouse.Config

      service :safe_telemetry do
        host "safe-telemetry.example.com"
        target :main, safe_rpc: [socket: #{inspect(socket)}, shards: 2], active: true
      end
      """)

    assert :ok = Gatehouse.Control.apply_config(config)

    request =
      :livery_req.new(%{
        method: "GET",
        scheme: "https",
        authority: "safe-telemetry.example.com",
        path: "/hello",
        raw_query: "",
        headers: [{"host", "safe-telemetry.example.com"}],
        body: :empty
      })

    response = Gatehouse.LiveryHandler.handle(request)

    assert Gatehouse.Livery.Response.status(response) == 200

    assert_receive {^ref, [:gatehouse, :safe_rpc, :pool, :checkout, :stop], %{duration: duration},
                    pool_metadata}

    assert is_integer(duration)
    assert pool_metadata.service == "safe_telemetry"
    assert pool_metadata.target_id == "main"
    assert pool_metadata.socket == socket
    assert pool_metadata.shards == 2
    assert pool_metadata.result == :ok

    assert_receive {^ref, [:gatehouse, :safe_rpc, :request, :stop], %{duration: duration},
                    request_metadata}

    assert is_integer(duration)
    assert request_metadata.service == "safe_telemetry"
    assert request_metadata.target_id == "main"
    assert request_metadata.socket == socket
    assert request_metadata.op == :http_request
    assert request_metadata.status == 200
    assert request_metadata.result == :ok

    :telemetry.detach(handler_id)
    GenServer.stop(server)
  after
    :telemetry.detach("gatehouse-safe-rpc-telemetry")
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

  def handle_event(event, measurements, metadata, {test_pid, ref}) do
    send(test_pid, {ref, event, measurements, metadata})
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(25)
      eventually(fun, attempts - 1)
  end

  defp eventually(fun, 0), do: fun.()

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "gatehouse-safe-rpc-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
