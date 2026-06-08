defmodule XamalProxy.Backend.Gun do
  @moduledoc """
  Gun-backed backend client for the reverse proxy runtime.

  `request/6` returns a buffered response for callers that need one.
  `stream/6` is used by the Livery runtime and streams backend response chunks
  through `livery_resp:stream/3`.
  """

  alias XamalProxy.Backend.{Connection, Response}

  @default_timeout 5_000

  @type response :: Response.t()
  @type stream_response ::
          {:full, response()}
          | {:stream, pos_integer(), [{binary(), binary()}], (function() -> :ok)}

  @spec request(URI.t(), binary(), binary(), [{binary(), binary()}], iodata(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(%URI{} = base_uri, method, path, headers, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, conn} <- Connection.open(base_uri, timeout),
         stream <- :gun.request(conn, method, path, headers, body),
         result <- await_buffered_response(conn, stream, timeout) do
      :gun.close(conn)
      result
    end
  end

  @spec stream(URI.t(), binary(), binary(), [{binary(), binary()}], term(), keyword()) ::
          {:ok, stream_response()} | {:error, term()}
  def stream(%URI{} = base_uri, method, path, headers, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, conn} <- Connection.open(base_uri, timeout),
         {:ok, stream} <- send_request(conn, method, path, headers, body, timeout) do
      case :gun.await(conn, stream, timeout) do
        {:response, :fin, status, response_headers} ->
          :gun.close(conn)
          {:ok, {:full, %Response{status: status, headers: response_headers, body: <<>>}}}

        {:response, :nofin, status, response_headers} ->
          {:ok, {:stream, status, response_headers, stream_producer(conn, stream, timeout)}}

        {:error, reason} ->
          :gun.close(conn)
          {:error, reason}
      end
    end
  end

  defp send_request(conn, method, path, headers, {:stream, reader}, timeout) do
    stream = :gun.headers(conn, method, path, headers)

    case send_request_stream(conn, stream, reader, timeout) do
      :ok -> {:ok, stream}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_request(conn, method, path, headers, body, _timeout) do
    {:ok, :gun.request(conn, method, path, headers, body)}
  end

  defp send_request_stream(conn, stream, reader, timeout) do
    case :livery_body.read(reader, timeout) do
      {:ok, chunk, next_reader} ->
        :ok = :gun.data(conn, stream, :nofin, chunk)
        send_request_stream(conn, stream, next_reader, timeout)

      {:done, _next_reader} ->
        :ok = :gun.data(conn, stream, :fin, <<>>)
        :ok

      {:error, reason, _next_reader} ->
        {:error, reason}
    end
  end

  defp stream_producer(conn, stream, timeout) do
    fn emit ->
      try do
        emit_stream(conn, stream, timeout, emit)
      after
        :gun.close(conn)
      end
    end
  end

  defp emit_stream(conn, stream, timeout, emit) do
    case :gun.await(conn, stream, timeout) do
      {:data, :nofin, data} ->
        case emit.(data) do
          :ok -> emit_stream(conn, stream, timeout, emit)
          {:error, _reason} -> :ok
        end

      {:data, :fin, data} ->
        emit.(data)
        :ok

      {:trailers, _trailers} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp await_buffered_response(conn, stream, timeout) do
    case :gun.await(conn, stream, timeout) do
      {:response, :fin, status, headers} ->
        {:ok, %Response{status: status, headers: headers, body: <<>>}}

      {:response, :nofin, status, headers} ->
        case :gun.await_body(conn, stream, timeout) do
          {:ok, body} -> {:ok, %Response{status: status, headers: headers, body: body}}
          {:ok, body, _trailers} -> {:ok, %Response{status: status, headers: headers, body: body}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
