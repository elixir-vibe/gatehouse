defmodule DemoApp.Server do
  @moduledoc """
  Tiny Livery backend used as a playground target for `xamal_proxy`.
  """

  use GenServer

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

    case :livery.start_service(%{http: %{port: port}, handler: handler(label)}) do
      {:ok, service} -> {:ok, %{service: service, port: h1_port(service)}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl GenServer
  def terminate(_reason, %{service: service}) do
    :livery.stop_service(service)
  end

  def terminate(_reason, _state), do: :ok

  defp handler(label) do
    fn request ->
      case :livery_req.path(request) do
        "/up" ->
          :livery_resp.text(200, "ok\n")

        "/echo" ->
          :livery_resp.text(200, request_body(request))

        "/stream" ->
          :livery_resp.stream(200, [{"content-type", "text/plain"}], fn emit ->
            Enum.each(["demo_", "app:", label, "\n"], &emit.(&1))
          end)

        _path ->
          :livery_resp.text(200, "demo_app:#{label}\n")
      end
    end
  end

  defp request_body(request) do
    case :livery_req.body(request) do
      :empty ->
        <<>>

      {:buffered, body} ->
        body

      {:stream, reader} ->
        case :livery_body.read_all(reader, 30_000) do
          {:ok, body, _reader} -> body
          {:error, reason, _reader} -> "read error: #{inspect(reason)}"
        end
    end
  end

  defp h1_port(service) do
    service
    |> :livery.which_listeners()
    |> Map.fetch!(:h1)
  end
end
