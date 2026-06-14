defmodule Gatehouse.Backend.Connection do
  @moduledoc false

  @spec open(URI.t(), timeout()) :: {:ok, pid()} | {:error, term()}
  def open(%URI{} = uri, timeout) do
    port = uri.port || default_port(uri.scheme)

    with {:ok, conn} <- :gun.open(String.to_charlist(uri.host), port, gun_opts(uri)),
         {:ok, _protocol} <- :gun.await_up(conn, timeout) do
      {:ok, conn}
    end
  end

  defp gun_opts(%URI{scheme: "https"}), do: %{transport: :tls, protocols: [:http]}
  defp gun_opts(_uri), do: %{transport: :tcp, protocols: [:http]}

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
