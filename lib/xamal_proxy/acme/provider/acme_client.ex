defmodule XamalProxy.Acme.Provider.AcmeClient do
  @moduledoc """
  ACME provider adapter backed by the Erlang `acme_client` package.
  """

  @behaviour XamalProxy.Acme.Provider

  alias XamalProxy.Acme.ChallengeStore

  @default_directory_url "https://acme-staging-v02.api.letsencrypt.org/directory"
  @default_timeout 60_000

  @impl XamalProxy.Acme.Provider
  def order_certificate(domains, opts) when is_list(domains) and is_list(opts) do
    request = %{
      dir_url: Keyword.get(opts, :directory_url, @default_directory_url),
      domains: Enum.map(domains, &to_domain_binary/1),
      contact: contact(opts),
      cert_type: Keyword.get(opts, :cert_type, :ec),
      challenge_type: "http-01",
      challenge_fn: &put_http01_challenges/1,
      output_dir: Keyword.get(opts, :output_dir),
      acc_key: Keyword.get(opts, :account_key),
      acc_key_pass: Keyword.get(opts, :account_key_pass),
      httpc_opts: Keyword.get(opts, :httpc_opts, %{})
    }

    request =
      request
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    run_acme_client(request, Keyword.get(opts, :timeout, @default_timeout))
  end

  @impl XamalProxy.Acme.Provider
  def renew_certificate(_certificate, opts) when is_list(opts) do
    opts
    |> Keyword.fetch!(:domains)
    |> order_certificate(opts)
  end

  @impl XamalProxy.Acme.Provider
  def revoke_certificate(_certificate, opts) when is_list(opts) do
    {:error, {:not_implemented, :revoke, opts}}
  end

  defp run_acme_client(request, timeout) do
    if Code.ensure_loaded?(:acme_client) and function_exported?(:acme_client, :run, 2) do
      :acme_client
      |> apply(:run, [request, timeout])
      |> normalize_result()
    else
      {:error, {:missing_dependency, :acme_client}}
    end
  end

  defp put_http01_challenges(challenges) do
    Enum.each(challenges, fn %{domain: domain, token: token, key: key} ->
      ChallengeStore.put(to_string(domain), to_string(token), to_string(key))
    end)
  end

  defp normalize_result({:ok, result}) do
    {:ok,
     %{
       cert_pem: Map.get(result, :cert_chain),
       key_pem: Map.get(result, :cert_key),
       account_key: Map.get(result, :acc_key),
       raw: result
     }}
  end

  defp normalize_result({:error, reason}), do: {:error, reason}

  defp contact(opts) do
    case Keyword.get(opts, :email) do
      nil -> Keyword.get(opts, :contact, [])
      email -> ["mailto:#{email}"]
    end
  end

  defp to_domain_binary(domain) when is_binary(domain), do: domain
  defp to_domain_binary(domain), do: to_string(domain)
end
