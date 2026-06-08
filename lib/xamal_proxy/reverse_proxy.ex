defmodule XamalProxy.ReverseProxy do
  @moduledoc """
  Small non-streaming HTTP reverse-proxy prototype.

  This is enough to validate routing, control-plane switching, and request
  accounting. It is not the final production proxy runtime.
  """

  alias XamalProxy.Backend.Gun
  alias XamalProxy.Control
  alias XamalProxy.RouteTable

  @recv_timeout 5_000

  @spec handle(:gen_tcp.socket()) :: :ok
  def handle(socket) do
    with {:ok, request} <- recv_request(socket),
         {:ok, service, target_id} <- route(request),
         {:ok, target} <- Control.checkout(service, target_id) do
      try do
        proxy(socket, request, target.url)
      after
        Control.checkin(service, target_id)
      end
    else
      {:error, :not_found} -> respond(socket, 404, "not found")
      {:error, reason} -> respond(socket, 502, "bad gateway: #{inspect(reason)}")
    end

    :gen_tcp.close(socket)
  end

  defp recv_request(socket) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> parse_request(data)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_request(data) do
    [head | body_parts] = String.split(data, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n")

    case String.split(request_line, " ", parts: 3) do
      [method, path, _version] ->
        headers = parse_headers(header_lines)

        {:ok,
         %{method: method, path: path, headers: headers, body: Enum.join(body_parts, "\r\n\r\n")}}

      _ ->
        {:error, :bad_request}
    end
  end

  defp parse_headers(lines) do
    Map.new(lines, fn line ->
      [name, value] = String.split(line, ":", parts: 2)
      {String.downcase(String.trim(name)), String.trim(value)}
    end)
  end

  defp route(%{headers: headers}) do
    headers
    |> Map.get("host", "")
    |> String.split(":", parts: 2)
    |> hd()
    |> RouteTable.lookup()
  end

  defp proxy(socket, request, target_url) do
    uri = URI.merge(target_url, request.path)
    headers = outbound_headers(request.headers)

    case Gun.request(uri, request.method, uri_path(uri), headers, request.body) do
      {:ok, response} ->
        raw_headers = Enum.map(response.headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{response.status} OK\r\n",
          raw_headers,
          "\r\n",
          response.body
        ])

      {:error, reason} ->
        respond(socket, 502, "bad gateway: #{inspect(reason)}")
    end
  end

  defp outbound_headers(headers) do
    headers
    |> Map.delete("host")
    |> Enum.map(fn {name, value} -> {name, value} end)
  end

  defp uri_path(%URI{path: nil, query: nil}), do: "/"
  defp uri_path(%URI{path: nil, query: query}), do: "/?#{query}"
  defp uri_path(%URI{path: path, query: nil}), do: path
  defp uri_path(%URI{path: path, query: query}), do: "#{path}?#{query}"

  defp respond(socket, status, body) do
    reason = if status == 404, do: "Not Found", else: "Bad Gateway"

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "content-type: text/plain\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])
  end
end
