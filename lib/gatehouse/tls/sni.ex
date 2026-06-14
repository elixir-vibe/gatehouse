defmodule Gatehouse.TLS.SNI do
  @moduledoc """
  Builds Erlang/OTP `:ssl` SNI options for certificate lookup.
  """

  alias Gatehouse.CertificateStore.File, as: FileStore

  @spec ssl_opts(keyword()) :: keyword()
  def ssl_opts(opts) when is_list(opts) do
    store = Keyword.get(opts, :store, FileStore)
    store_opts = Keyword.get(opts, :store_opts) || store_opts(opts)

    [{:sni_fun, &certificate_options(&1, store, store_opts)}]
  end

  @spec certificate_options(charlist() | binary(), module(), keyword()) :: keyword()
  def certificate_options(server_name, store, store_opts) do
    server_name
    |> normalize_name()
    |> store.paths(store_opts)
    |> case do
      {:ok, %{certfile: certfile, keyfile: keyfile}} -> [certfile: certfile, keyfile: keyfile]
      {:error, _reason} -> []
    end
  end

  defp normalize_name(server_name) when is_list(server_name) do
    server_name
    |> List.to_string()
    |> normalize_name()
  end

  defp normalize_name(server_name) when is_binary(server_name) do
    server_name
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp store_opts(opts) do
    [directory: Keyword.fetch!(opts, :cert_directory)]
  end
end
