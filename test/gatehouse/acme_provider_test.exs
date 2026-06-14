defmodule Gatehouse.ACMEProviderTest do
  use ExUnit.Case, async: true

  alias Gatehouse.ACME.ChallengeStore
  alias Gatehouse.ACME.Provider.ExAcme, as: ExAcmeProvider

  test "ex_acme adapter exposes provider callbacks" do
    assert Code.ensure_loaded?(ExAcmeProvider)
    assert function_exported?(ExAcmeProvider, :order_certificate, 2)
    assert function_exported?(ExAcmeProvider, :renew_certificate, 2)
    assert function_exported?(ExAcmeProvider, :revoke_certificate, 2)
  end

  test "ex_acme adapter stores HTTP-01 key authorization" do
    account_key = ExAcme.AccountKey.new(ExAcme.generate_key(), "kid")
    challenge = %ExAcme.Challenge{token: "token"}

    assert :ok = ExAcmeProvider.put_http01_challenge("example.com", challenge, account_key)
    assert {:ok, key_authorization} = ChallengeStore.get("example.com", "token")
    assert key_authorization == ExAcme.Challenge.key_authorization("token", account_key)
  end
end
