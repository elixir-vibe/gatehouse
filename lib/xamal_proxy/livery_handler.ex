defmodule XamalProxy.LiveryHandler do
  @moduledoc """
  Livery request handler for the proxy runtime.
  """

  alias XamalProxy.ACME.ChallengeStore
  alias XamalProxy.Backend.Gun
  alias XamalProxy.Control
  alias XamalProxy.Livery.{Request, Response, WebSocket}
  alias XamalProxy.RouteTable
  alias XamalProxy.Telemetry

  @hop_by_hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)

  @spec handle(term()) :: term()
  def handle(request) do
    start = System.monotonic_time()

    with :proxy <- maybe_http01_challenge(request),
         {:ok, service, target_id} <- route(request),
         {:ok, target} <- Control.checkout(service, target_id) do
      response = maybe_upgrade_websocket(request, target.url) || forward(request, target.url)
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
        Response.text(502, "bad gateway: #{inspect(reason)}")
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
  end

  defp maybe_upgrade_websocket(request, target_url) do
    if websocket_upgrade?(request) do
      WebSocket.upgrade(request, XamalProxy.WebSocketProxy, %{
        target_url: target_url,
        path: path_with_query(request),
        headers: outbound_headers(Request.headers(request))
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
    body = request_body(Request.body(request))

    case Gun.stream(target_url, method, path, headers, body) do
      {:ok, {:full, response}} ->
        Response.new(response.status, response_headers(response.headers), {:full, response.body})

      {:ok, {:stream, status, headers, producer}} ->
        Response.stream(status, response_headers(headers), producer)

      {:error, reason} ->
        Response.text(502, "bad gateway: #{inspect(reason)}")
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

  defp request_body(:empty), do: <<>>
  defp request_body({:buffered, body}), do: body
  defp request_body({:stream, reader}), do: {:stream, reader}

  defp outbound_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> hop_by_hop?(name) end)
    |> Enum.map(fn {name, value} -> {to_binary(name), to_binary(value)} end)
  end

  defp response_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> hop_by_hop?(name) end)
    |> Enum.map(fn {name, value} -> {to_binary(name), to_binary(value)} end)
  end

  defp hop_by_hop?(name) do
    Enum.member?(@hop_by_hop_headers, String.downcase(to_string(name)))
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
