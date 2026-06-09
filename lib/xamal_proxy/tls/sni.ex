defmodule XamalProxy.TLS.SNI do
  @moduledoc """
  Builds Erlang/OTP `:ssl` SNI options for certificate lookup.
  """

  @spec ssl_opts(keyword()) :: keyword()
  def ssl_opts(opts) when is_list(opts) do
    cert_directory = Keyword.fetch!(opts, :cert_directory)
    [{:sni_fun, &certificate_options(&1, cert_directory)}]
  end

  @spec certificate_options(charlist() | binary(), Path.t()) :: keyword()
  def certificate_options(server_name, cert_directory) when is_binary(cert_directory) do
    name = normalize_name(server_name)
    certfile = Path.join(cert_directory, "#{name}.crt")
    keyfile = Path.join(cert_directory, "#{name}.key")

    if File.regular?(certfile) and File.regular?(keyfile) do
      [certfile: certfile, keyfile: keyfile]
    else
      []
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
end
