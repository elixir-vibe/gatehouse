defmodule Gatehouse.LiveryHandler do
  @moduledoc """
  Livery request handler for the proxy runtime.
  """

  alias Gatehouse.ACME.ChallengeStore
  alias Gatehouse.Backend.Gun
  alias Gatehouse.Control
  alias Gatehouse.Livery.{Request, Response, WebSocket}
  alias Gatehouse.RouteTable
  alias Gatehouse.SafeRPC
  alias Gatehouse.Telemetry

  @hop_by_hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)

  @spec handle(term()) :: term()
  def handle(request) do
    start = System.monotonic_time()

    with :proxy <- maybe_http01_challenge(request),
         {:ok, service, target_id} <- route(request),
         {:ok, target} <- Control.checkout(service, target_id) do
      response = forward_target(request, target, service, target_id)
      emit_request_telemetry(start, service, target_id, response)
      finalize_response(response, service, target_id)
    else
      {:ok, response} ->
        response

      {:error, :not_found} ->
        emit_request_telemetry(start, nil, nil, 404)
        Response.text(404, "not found")

      {:error, reason} ->
        emit_request_telemetry(start, nil, nil, 502, %{error: reason})
        Response.text(502, "bad gateway")
    end
  end

  defp maybe_http01_challenge(request) do
    case String.split(to_string(Request.path(request)), "/.well-known/acme-challenge/", parts: 2) do
      ["", token] -> serve_http01_challenge(request, token)
      _other -> :proxy
    end
  end

  defp serve_http01_challenge(request, token) do
    case ChallengeStore.get(Request.host(request), token) do
      {:ok, key_authorization} -> {:ok, Response.text(200, key_authorization)}
      :error -> {:ok, Response.text(404, "not found")}
    end
  end

  defp route(request) do
    request
    |> Request.host()
    |> RouteTable.lookup()
    |> case do
      :error -> {:error, :not_found}
      route -> route
    end
  end

  defp forward_target(request, %{kind: :safe_rpc} = target, service, target_id) do
    case checkout_safe_rpc_pool(target, service, target_id) do
      {:ok, pool} ->
        SafeRPC.Forwarder.forward(request, pool, route_key(request),
          op: target.op,
          service: service,
          target_id: target_id,
          socket: target.socket,
          shards: target.shards
        )

      {:error, reason} ->
        Response.text(502, upstream_error_body(reason))
    end
  end

  defp forward_target(request, %{kind: :http, url: url}, _service, _target_id) do
    maybe_upgrade_websocket(request, url) || forward(request, url)
  end

  defp upstream_error_body(_reason), do: "bad gateway"

  defp maybe_upgrade_websocket(request, target_url) do
    if websocket_upgrade?(request) do
      WebSocket.upgrade(request, Gatehouse.WebSocketProxy, %{
        target_url: target_url,
        path: path_with_query(request),
        headers: websocket_outbound_headers(Request.headers(request))
      })
    end
  end

  defp websocket_upgrade?(request) do
    connection = request |> Request.header(<<"connection">>) |> String.downcase()
    upgrade = request |> Request.header(<<"upgrade">>) |> String.downcase()

    String.contains?(connection, "upgrade") and upgrade == "websocket"
  end

  defp forward(request, target_url) do
    method = Request.method(request)
    path = path_with_query(request)
    headers = outbound_headers(Request.headers(request))
    body = request_body(method, headers, Request.body(request))

    case Gun.stream(target_url, method, path, headers, body) do
      {:ok, {:full, response}} ->
        Response.new(response.status, response_headers(response.headers), {:full, response.body})

      {:ok, {:stream, status, headers, producer}} ->
        Response.stream(status, response_headers(headers), producer)

      {:error, _reason} ->
        Response.text(502, "bad gateway")
    end
  end

  defp finalize_response(response, service, target_id) do
    case Response.body(response) do
      {:chunked, producer} ->
        Response.with_body({:chunked, checkin_producer(producer, service, target_id)}, response)

      {:sse, producer} ->
        Response.with_body({:sse, checkin_producer(producer, service, target_id)}, response)

      _body ->
        Control.checkin(service, target_id)
        response
    end
  end

  defp checkin_producer(producer, service, target_id) do
    fn emit ->
      try do
        producer.(emit)
      after
        Control.checkin(service, target_id)
      end
    end
  end

  defp path_with_query(request) do
    path = Request.path(request)

    case Request.query(request) do
      query when query in [nil, "", <<>>] -> path
      query -> [path, ??, query] |> IO.iodata_to_binary()
    end
  end

  defp checkout_safe_rpc_pool(target, service, target_id) do
    start = System.monotonic_time()
    result = SafeRPC.Pool.checkout(target.socket, shards: target.shards)

    Telemetry.execute(
      [:safe_rpc, :pool, :checkout, :stop],
      %{duration: System.monotonic_time() - start},
      %{
        service: service,
        target_id: target_id,
        socket: target.socket,
        shards: target.shards,
        result: checkout_result(result)
      }
    )

    result
  end

  defp checkout_result({:ok, _pool}), do: :ok
  defp checkout_result({:error, reason}), do: {:error, reason}

  defp route_key(request), do: {Request.host(request), Request.path(request)}

  defp request_body(_method, _headers, :empty), do: <<>>
  defp request_body(_method, _headers, {:buffered, body}), do: body

  defp request_body(method, headers, {:stream, reader}) do
    if bodyless_request?(method, headers), do: <<>>, else: {:stream, reader}
  end

  defp bodyless_request?(method, headers) when method in [<<"GET">>, <<"HEAD">>] do
    not has_header?(headers, <<"content-length">>) and
      not has_header?(headers, <<"transfer-encoding">>)
  end

  defp bodyless_request?(_method, _headers), do: false

  defp has_header?(headers, wanted) do
    Enum.any?(headers, fn {name, _value} -> String.downcase(to_string(name)) == wanted end)
  end

  defp outbound_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> hop_by_hop?(name) end)
    |> Enum.map(fn {name, value} -> {to_binary(name), to_binary(value)} end)
  end

  defp websocket_outbound_headers(headers) do
    headers
    |> outbound_headers()
    |> Enum.reject(fn {name, _value} -> websocket_handshake_header?(name) end)
  end

  defp response_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> hop_by_hop?(name) end)
    |> Enum.map(fn {name, value} -> {to_binary(name), to_binary(value)} end)
  end

  defp hop_by_hop?(name) do
    Enum.member?(@hop_by_hop_headers, String.downcase(to_string(name)))
  end

  defp websocket_handshake_header?(name) do
    String.starts_with?(String.downcase(to_string(name)), "sec-websocket-")
  end

  defp emit_request_telemetry(start, service, target_id, response, metadata \\ %{}) do
    status = response_status(response)

    Telemetry.execute(
      [:proxy, :request, :stop],
      %{duration: System.monotonic_time() - start},
      Map.merge(metadata, %{service: service, target_id: target_id, status: status})
    )
  end

  defp response_status(response) when is_integer(response), do: response
  defp response_status(response), do: Response.status(response)

  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value), do: to_string(value)
end
