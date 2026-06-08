defmodule XamalProxy.Backend.Gun do
  @moduledoc """
  Small Gun-backed backend client for the reverse proxy runtime.

  This module currently buffers one response per request. It is the seam for the
  next step: streaming request/response bodies with backpressure.
  """

  @default_timeout 5_000

  @type response :: %{status: pos_integer(), headers: [{binary(), binary()}], body: binary()}

  @spec request(URI.t(), binary(), binary(), [{binary(), binary()}], iodata(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(%URI{} = base_uri, method, path, headers, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    port = base_uri.port || default_port(base_uri.scheme)

    with {:ok, conn} <- :gun.open(String.to_charlist(base_uri.host), port, gun_opts(base_uri)),
         {:ok, _protocol} <- :gun.await_up(conn, timeout) do
      stream = :gun.request(conn, method, path, headers, body)
      result = await_response(conn, stream, timeout, nil, [], [])
      :gun.close(conn)
      result
    end
  end

  defp await_response(conn, stream, timeout, status, headers, body) do
    receive do
      {:gun_response, ^conn, ^stream, :fin, response_status, response_headers} ->
        {:ok,
         %{status: response_status, headers: response_headers, body: IO.iodata_to_binary(body)}}

      {:gun_response, ^conn, ^stream, :nofin, response_status, response_headers} ->
        await_response(conn, stream, timeout, response_status, response_headers, body)

      {:gun_data, ^conn, ^stream, :fin, data} ->
        {:ok, %{status: status, headers: headers, body: IO.iodata_to_binary([body, data])}}

      {:gun_data, ^conn, ^stream, :nofin, data} ->
        await_response(conn, stream, timeout, status, headers, [body, data])

      {:gun_error, ^conn, ^stream, reason} ->
        {:error, reason}

      {:gun_error, ^conn, reason} ->
        {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp gun_opts(%URI{scheme: "https"}), do: %{transport: :tls, protocols: [:http]}
  defp gun_opts(_uri), do: %{transport: :tcp, protocols: [:http]}

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
