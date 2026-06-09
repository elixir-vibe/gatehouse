defmodule XamalProxy.ACME.Provider.ExAcme do
  @moduledoc """
  ACME provider backed by the Elixir `ex_acme` package.

  This adapter implements the full HTTP-01 order shape while keeping network and
  certificate details behind `XamalProxy.ACME.Provider`.
  """

  @behaviour XamalProxy.ACME.Provider

  alias ExAcme.{Challenge, Order, OrderBuilder, RegistrationBuilder, RevocationBuilder}
  alias XamalProxy.ACME.ChallengeStore

  @default_client __MODULE__.Client
  @default_directory_url :lets_encrypt_staging
  @default_poll_attempts 20
  @default_poll_interval 1_000

  @impl XamalProxy.ACME.Provider
  def order_certificate(domains, opts) when is_list(domains) and is_list(opts) do
    with {:ok, client, close?} <- client(opts) do
      try do
        do_order_certificate(domains, opts, client)
      after
        close(client, close?)
      end
    end
  end

  defp do_order_certificate(domains, opts, client) do
    with {:ok, account_key} <- account_key(client, opts),
         {:ok, order} <- submit_order(domains, account_key, client, opts),
         :ok <- authorize(order, account_key, client, opts),
         {:ok, private_key} <- certificate_key(opts),
         {:ok, csr} <- Order.to_csr(order, private_key),
         {:ok, finalized_order} <- finalize_order(order, csr, account_key, client, opts),
         {:ok, ready_order} <- poll_order(finalized_order, account_key, client, opts),
         {:ok, certs} <- fetch_certificates(ready_order, account_key, client, opts) do
      {:ok,
       %{
         cert_pem: certificates_to_pem(certs),
         key_pem: X509.PrivateKey.to_pem(private_key),
         account_key: account_key,
         raw: %{order: ready_order, certificates: certs}
       }}
    end
  end

  @impl XamalProxy.ACME.Provider
  def renew_certificate(_certificate, opts) when is_list(opts) do
    opts
    |> Keyword.fetch!(:domains)
    |> order_certificate(opts)
  end

  @impl XamalProxy.ACME.Provider
  def revoke_certificate(certificate, opts) when is_map(certificate) and is_list(opts) do
    with {:ok, client, close?} <- client(opts) do
      try do
        do_revoke_certificate(certificate, opts, client)
      after
        close(client, close?)
      end
    end
  end

  defp do_revoke_certificate(certificate, opts, client) do
    with {:ok, account_key} <- account_key(client, opts),
         cert_pem <- Map.get(certificate, :cert_pem) || Map.fetch!(certificate, :cert),
         revocation <-
           RevocationBuilder.new_revocation() |> RevocationBuilder.certificate(pem: cert_pem),
         result <- ExAcme.revoke_certificate(revocation, account_key, client) do
      normalize_ok(result)
    end
  end

  @spec put_http01_challenge(String.t(), Challenge.t(), ExAcme.AccountKey.t()) :: :ok
  def put_http01_challenge(domain, %Challenge{} = challenge, account_key) do
    ChallengeStore.put(
      domain,
      challenge.token,
      Challenge.key_authorization(challenge.token, account_key)
    )
  end

  defp client(opts) do
    case Keyword.get(opts, :client) do
      nil ->
        directory_url = Keyword.get(opts, :directory_url, @default_directory_url)
        name = Keyword.get(opts, :client_name, @default_client)

        case ExAcme.start_link(name: name, directory_url: directory_url) do
          {:ok, _pid} -> {:ok, name, true}
          {:error, {:already_started, _pid}} -> {:ok, name, false}
          {:error, reason} -> {:error, reason}
        end

      client ->
        {:ok, client, false}
    end
  end

  defp account_key(client, opts) do
    case Keyword.get(opts, :account_key) do
      nil -> register_account(client, opts)
      account_key -> {:ok, account_key}
    end
  end

  defp register_account(client, opts) do
    key = Keyword.get_lazy(opts, :jwk, &ExAcme.generate_key/0)

    registration =
      RegistrationBuilder.new_registration()
      |> maybe_contacts(opts)
      |> RegistrationBuilder.agree_to_terms()

    registration = maybe_external_account_binding(registration, key, client, opts)

    ExAcme.register_account(registration, key, client)
    |> case do
      {:ok, _account, account_key} -> {:ok, account_key}
      other -> normalize_retry(other)
    end
  end

  defp maybe_contacts(registration, opts) do
    cond do
      email = Keyword.get(opts, :email) ->
        RegistrationBuilder.contacts(registration, email: email)

      contacts = Keyword.get(opts, :contact) ->
        RegistrationBuilder.contacts(registration, contacts)

      true ->
        registration
    end
  end

  defp maybe_external_account_binding(registration, key, client, opts) do
    case {Keyword.get(opts, :eab_kid), Keyword.get(opts, :eab_mac_key)} do
      {kid, mac_key} when is_binary(kid) and is_binary(mac_key) ->
        RegistrationBuilder.external_account_binding(registration, key, client, kid, mac_key)

      _other ->
        registration
    end
  end

  defp submit_order(domains, account_key, client, opts) do
    OrderBuilder.new_order()
    |> OrderBuilder.add_dns_identifier(Enum.map(domains, &to_string/1))
    |> maybe_profile(opts)
    |> ExAcme.submit_order(account_key, client)
    |> normalize_retry()
  end

  defp maybe_profile(order, opts) do
    case Keyword.get(opts, :profile) do
      nil -> order
      profile -> OrderBuilder.profile(order, profile)
    end
  end

  defp authorize(order, account_key, client, opts) do
    Enum.reduce_while(order.authorizations, :ok, fn authorization_url, :ok ->
      case authorize_one(authorization_url, account_key, client, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authorize_one(authorization_url, account_key, client, opts) do
    with {:ok, authorization} <-
           ExAcme.fetch_authorization(authorization_url, account_key, client),
         %Challenge{} = challenge <- Challenge.find_by_type(authorization, "http-01"),
         domain <- authorization.identifier["value"],
         :ok <- put_http01_challenge(domain, challenge, account_key),
         {:ok, challenge} <- ExAcme.start_challenge_validation(challenge, account_key, client),
         {:ok, _challenge} <- poll_challenge(challenge.url, account_key, client, opts) do
      :ok
    else
      nil -> {:error, {:missing_challenge, "http-01"}}
      {:retry_after, _seconds} = retry -> normalize_retry(retry)
      {:error, reason} -> {:error, reason}
    end
  end

  defp poll_challenge(url, account_key, client, opts) do
    attempts = Keyword.get(opts, :poll_attempts, @default_poll_attempts)
    interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    poll_challenge(url, account_key, client, attempts, interval)
  end

  defp poll_challenge(_url, _account_key, _client, 0, _interval),
    do: {:error, :max_attempts_reached}

  defp poll_challenge(url, account_key, client, attempts, interval) do
    case ExAcme.fetch_challenge(url, account_key, client) do
      {:ok, %Challenge{status: "valid"} = challenge} ->
        {:ok, challenge}

      {:ok, %Challenge{status: "invalid"} = challenge} ->
        {:error, {:challenge_failed, challenge}}

      {:ok, %Challenge{}} ->
        Process.sleep(interval)
        poll_challenge(url, account_key, client, attempts - 1, interval)

      {:retry_after, seconds} ->
        Process.sleep(seconds * 1_000)
        poll_challenge(url, account_key, client, attempts - 1, interval)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp certificate_key(opts) do
    case Keyword.get(opts, :private_key) do
      nil -> {:ok, X509.PrivateKey.new_ec(:secp256r1)}
      key -> {:ok, key}
    end
  end

  defp finalize_order(order, csr, account_key, client, _opts) do
    ExAcme.finalize_order(order, csr, account_key, client)
    |> normalize_retry()
  end

  defp poll_order(
         %Order{status: "valid", certificate_url: certificate_url} = order,
         _account_key,
         _client,
         _opts
       )
       when is_binary(certificate_url),
       do: {:ok, order}

  defp poll_order(order, account_key, client, opts) do
    attempts = Keyword.get(opts, :poll_attempts, @default_poll_attempts)
    interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    poll_order(order.url, account_key, client, attempts, interval)
  end

  defp poll_order(_url, _account_key, _client, 0, _interval), do: {:error, :max_attempts_reached}

  defp poll_order(url, account_key, client, attempts, interval) do
    case ExAcme.fetch_order(url, account_key, client) do
      {:ok, %Order{status: "valid", certificate_url: certificate_url} = order}
      when is_binary(certificate_url) ->
        {:ok, order}

      {:ok, %Order{status: "invalid"} = order} ->
        {:error, {:order_failed, order}}

      {:ok, %Order{}} ->
        Process.sleep(interval)
        poll_order(url, account_key, client, attempts - 1, interval)

      {:retry_after, seconds} ->
        Process.sleep(seconds * 1_000)
        poll_order(url, account_key, client, attempts - 1, interval)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_certificates(%Order{certificate_url: certificate_url}, account_key, client, _opts) do
    ExAcme.fetch_certificates(certificate_url, account_key, client)
    |> normalize_retry()
  end

  defp certificates_to_pem(certs) do
    certs
    |> List.wrap()
    |> Enum.map(&X509.Certificate.to_pem/1)
    |> IO.iodata_to_binary()
  end

  defp normalize_retry({:retry_after, seconds}), do: {:error, {:retry_after, seconds}}
  defp normalize_retry(other), do: other

  defp normalize_ok(:ok), do: :ok
  defp normalize_ok({:retry_after, seconds}), do: {:error, {:retry_after, seconds}}
  defp normalize_ok({:error, reason}), do: {:error, reason}

  defp close(client, true) when is_pid(client), do: Agent.stop(client)
  defp close(client, true) when is_atom(client), do: client |> Process.whereis() |> close(true)
  defp close(_client, _close?), do: :ok
end
