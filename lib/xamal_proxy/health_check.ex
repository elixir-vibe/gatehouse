defmodule XamalProxy.HealthCheck do
  @moduledoc """
  Minimal backend health checks used before switching traffic.
  """

  @type result :: :ok | {:error, term()}

  @spec check(URI.t(), keyword()) :: result()
  def check(%URI{} = base_uri, opts \\ []) do
    path = Keyword.get(opts, :path, "/up")
    timeout = Keyword.get(opts, :timeout, 5_000)

    base_uri
    |> URI.append_path(path)
    |> URI.to_string()
    |> String.to_charlist()
    |> request(timeout)
  end

  defp request(url, timeout) do
    http_options = [autoredirect: false, timeout: timeout]

    case :httpc.request(:get, {url, []}, http_options, []) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..399 -> :ok
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
