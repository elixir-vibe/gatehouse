defmodule XamalProxy.SafeRPC.Forwarder do
  @moduledoc "Forwards Livery requests to SafeRPC HTTP envelope upstreams."

  alias XamalProxy.Livery.Request
  alias XamalProxy.Livery.Response, as: LiveryResponse
  alias XamalProxy.SafeRPC.HTTP

  @spec forward(term(), pid(), term(), keyword()) :: term()
  def forward(request, pool, key, opts \\ []) when is_pid(pool) do
    op = Keyword.get(opts, :op, :http_request)
    timeout = Keyword.get(opts, :timeout, 15_000)
    envelope = HTTP.from_livery(request, opts)

    case SafeRPC.ClientPool.call(pool, key, op, envelope,
           timeout: timeout,
           meta: request_meta(request)
         ) do
      {:ok, response} -> HTTP.to_livery(response)
      {:error, :unauthorized} -> LiveryResponse.text(403, "forbidden")
      {:error, :forbidden} -> LiveryResponse.text(403, "forbidden")
      {:error, reason} -> LiveryResponse.text(502, "bad gateway: #{inspect(reason)}")
    end
  end

  defp request_meta(request) do
    %{
      host: Request.host(request),
      path: request |> Request.path() |> to_string()
    }
  end
end
