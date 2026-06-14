defmodule Gatehouse.SafeRPC.Forwarder do
  @moduledoc "Forwards Livery requests to SafeRPC HTTP envelope upstreams."

  alias Gatehouse.Livery.Request
  alias Gatehouse.Livery.Response, as: LiveryResponse
  alias Gatehouse.SafeRPC.HTTP
  alias Gatehouse.SafeRPC.Pool
  alias Gatehouse.Telemetry

  @spec forward(term(), pid(), term(), keyword()) :: term()
  def forward(request, pool, key, opts \\ []) when is_pid(pool) do
    op = Keyword.get(opts, :op, :http_request)
    timeout = Keyword.get(opts, :timeout, 15_000)
    envelope = HTTP.from_livery(request, opts)
    start = System.monotonic_time()

    result = call_pool(pool, key, op, envelope, timeout, request, opts)

    response = response_from_result(result)
    emit_request_telemetry(start, opts, op, response, result)
    response
  end

  defp call_pool(pool, key, op, envelope, timeout, request, opts) do
    SafeRPC.ClientPool.call(pool, key, op, envelope,
      timeout: timeout,
      meta: request_meta(request)
    )
  catch
    :exit, reason ->
      Pool.invalidate(Keyword.fetch!(opts, :socket), shards: Keyword.get(opts, :shards, 1))
      {:error, normalize_exit(reason)}
  end

  defp response_from_result({:ok, response}), do: HTTP.to_livery(response)
  defp response_from_result({:error, :unauthorized}), do: LiveryResponse.text(403, "forbidden")
  defp response_from_result({:error, :forbidden}), do: LiveryResponse.text(403, "forbidden")
  defp response_from_result({:error, _reason}), do: LiveryResponse.text(502, "bad gateway")

  defp normalize_exit({:noproc, {GenServer, :call, _args}}), do: :closed
  defp normalize_exit({:normal, {GenServer, :call, _args}}), do: :closed
  defp normalize_exit(reason), do: {:safe_rpc_exit, reason}

  defp emit_request_telemetry(start, opts, op, response, result) do
    Telemetry.execute(
      [:safe_rpc, :request, :stop],
      %{duration: System.monotonic_time() - start},
      %{
        service: Keyword.get(opts, :service),
        target_id: Keyword.get(opts, :target_id),
        socket: Keyword.get(opts, :socket),
        op: op,
        status: LiveryResponse.status(response),
        result: telemetry_result(result)
      }
    )
  end

  defp telemetry_result({:ok, _response}), do: :ok
  defp telemetry_result({:error, reason}), do: {:error, reason}

  defp request_meta(request) do
    %{
      host: Request.host(request),
      path: request |> Request.path() |> to_string()
    }
  end
end
