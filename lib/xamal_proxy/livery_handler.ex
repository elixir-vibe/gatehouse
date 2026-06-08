defmodule XamalProxy.LiveryHandler do
  @moduledoc """
  Livery request handler for the proxy runtime.
  """

  alias XamalProxy.Backend.Gun
  alias XamalProxy.Control
  alias XamalProxy.RouteTable
  alias XamalProxy.Telemetry

  @hop_by_hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)

  @spec handle(term()) :: term()
  def handle(request) do
    start = System.monotonic_time()

    with {:ok, service, target_id} <- route(request),
         {:ok, target} <- Control.checkout(service, target_id) do
      try do
        response = maybe_upgrade_websocket(request, target.url) || forward(request, target.url)
        emit_request_telemetry(start, service, target_id, response)
        response
      after
        Control.checkin(service, target_id)
      end
    else
      {:error, :not_found} ->
        emit_request_telemetry(start, nil, nil, 404)
        :livery_resp.text(404, "not found")

      {:error, reason} ->
        emit_request_telemetry(start, nil, nil, 502, %{error: reason})
        :livery_resp.text(502, "bad gateway: #{inspect(reason)}")
    end
  end

  defp route(request) do
    <<"host">>
    |> :livery_req.header(request, <<>>)
    |> to_string()
    |> String.split(":", parts: 2)
    |> hd()
    |> RouteTable.lookup()
  end

  defp maybe_upgrade_websocket(request, target_url) do
    if websocket_upgrade?(request) do
      :livery_ws.upgrade(request, XamalProxy.WebSocketProxy, %{
        target_url: target_url,
        path: path_with_query(request),
        headers: outbound_headers(:livery_req.headers(request))
      })
    end
  end

  defp websocket_upgrade?(request) do
    connection = <<"connection">> |> :livery_req.header(request, <<>>) |> String.downcase()
    upgrade = <<"upgrade">> |> :livery_req.header(request, <<>>) |> String.downcase()

    String.contains?(connection, "upgrade") and upgrade == "websocket"
  end

  defp forward(request, target_url) do
    method = :livery_req.method(request)
    path = path_with_query(request)
    headers = outbound_headers(:livery_req.headers(request))
    body = request_body(:livery_req.body(request))

    case Gun.stream(target_url, method, path, headers, body) do
      {:ok, {:full, response}} ->
        :livery_resp.new(
          response.status,
          response_headers(response.headers),
          {:full, response.body}
        )

      {:ok, {:stream, status, headers, producer}} ->
        :livery_resp.stream(status, response_headers(headers), producer)

      {:error, reason} ->
        :livery_resp.text(502, "bad gateway: #{inspect(reason)}")
    end
  end

  defp path_with_query(request) do
    path = :livery_req.path(request)

    case :livery_req.query(request) do
      query when query in [nil, "", <<>>] -> path
      query -> [path, ??, query] |> IO.iodata_to_binary()
    end
  end

  defp request_body(:empty), do: <<>>
  defp request_body({:buffered, body}), do: body

  defp request_body({:stream, reader}) do
    case :livery_body.read_all(reader, 30_000) do
      {:ok, body, _next_reader} -> body
      {:error, _reason, _next_reader} -> <<>>
    end
  end

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
  defp response_status(response), do: :livery_resp.status(response)

  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value), do: to_string(value)
end
