defmodule Gatehouse.SafeRPC.HTTP do
  @moduledoc "Converts between Livery HTTP terms and SafeRPC HTTP envelopes."

  alias SafeRPC.Adapter.HTTP.{Request, Response}
  alias Gatehouse.Livery

  @spec from_livery(term(), keyword()) :: term()
  def from_livery(request, opts \\ []) do
    %Request{
      method: request |> Livery.Request.method() |> to_string(),
      scheme: opts |> Keyword.get(:scheme, "https") |> to_string(),
      host: Livery.Request.host(request),
      port: Keyword.get(opts, :port, default_port(Keyword.get(opts, :scheme, "https"))),
      path: request |> Livery.Request.path() |> to_string(),
      query: request |> Livery.Request.query() |> to_string(),
      headers: normalize_headers(Livery.Request.headers(request)),
      body: normalize_body(Livery.Request.body(request)),
      remote_ip: Keyword.get(opts, :remote_ip)
    }
  end

  @spec to_livery(term()) :: term()
  def to_livery(%Response{status: status, headers: headers, body: body}) do
    Livery.Response.new(status, normalize_headers(headers), to_livery_body(body))
  end

  defp normalize_body(:empty), do: :empty
  defp normalize_body({:buffered, body}), do: {:full, body}
  defp normalize_body({:stream, _reader}), do: {:error, :streaming_request_body_not_supported}

  defp to_livery_body(:empty), do: :empty
  defp to_livery_body({:full, body}), do: {:full, body}

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp default_port("http"), do: 80
  defp default_port(:http), do: 80
  defp default_port(_scheme), do: 443
end
