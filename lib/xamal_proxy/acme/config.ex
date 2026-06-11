defmodule XamalProxy.ACME.Config do
  @moduledoc """
  Converts static proxy config into ACME renewal jobs.
  """

  alias XamalProxy.Config
  alias XamalProxy.Config.Service
  alias XamalProxy.TLS.SNI

  @default_cert_directory "/var/lib/xamal-proxy/certs"
  @default_account_directory "/var/lib/xamal-proxy/acme"
  @default_provider XamalProxy.ACME.Provider.ExAcme
  @default_store XamalProxy.CertificateStore.File

  @type job :: %{
          required(:name) => String.t(),
          required(:domains) => [String.t()],
          required(:provider) => module(),
          required(:provider_opts) => keyword(),
          required(:store) => module(),
          required(:store_opts) => keyword(),
          optional(:renew_before_days) => pos_integer()
        }

  @spec jobs(Config.t()) :: [job()]
  def jobs(%Config{acme: nil}), do: []

  def jobs(%Config{services: services, acme: acme}) when is_list(acme) do
    services
    |> Enum.filter(&auto_tls?/1)
    |> Enum.reject(&Enum.empty?(&1.hosts))
    |> Enum.map(&service_job(&1, acme))
  end

  @spec sni_ssl_opts(Config.t()) :: keyword()
  def sni_ssl_opts(%Config{acme: nil}), do: []

  def sni_ssl_opts(%Config{services: services, acme: acme}) when is_list(acme) do
    if Enum.any?(services, &auto_tls?/1) and store(acme) == @default_store do
      SNI.ssl_opts(store: store(acme), store_opts: store_opts(acme))
    else
      []
    end
  end

  defp service_job(%Service{} = service, acme) do
    name = Keyword.get(acme, :name, List.first(service.hosts))
    account_directory = Keyword.get(acme, :account_directory, @default_account_directory)

    %{
      name: name,
      domains: service.hosts,
      provider: Keyword.get(acme, :provider, @default_provider),
      provider_opts: provider_opts(acme, name, account_directory),
      store: store(acme),
      store_opts: store_opts(acme),
      renew_before_days: Keyword.get(acme, :renew_before_days, 30)
    }
  end

  defp store(acme), do: Keyword.get(acme, :store, @default_store)

  defp store_opts(acme) do
    Keyword.get(acme, :store_opts,
      directory: Keyword.get(acme, :cert_directory, @default_cert_directory)
    )
  end

  defp provider_opts(acme, name, account_directory) do
    acme
    |> Keyword.drop([
      :account_directory,
      :cert_directory,
      :name,
      :provider,
      :renew_before_days,
      :store,
      :store_opts
    ])
    |> Keyword.put_new(:account_key_path, Path.join(account_directory, "#{name}.account.term"))
  end

  defp auto_tls?(%Service{tls: :auto}), do: true
  defp auto_tls?(%Service{tls: tls}) when is_list(tls), do: Keyword.get(tls, :mode) == :auto
  defp auto_tls?(_service), do: false
end
