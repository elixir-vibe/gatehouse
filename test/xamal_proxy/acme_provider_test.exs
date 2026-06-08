defmodule XamalProxy.ACMEProviderTest do
  use ExUnit.Case, async: true

  alias XamalProxy.ACME.Provider.AcmeClient

  test "acme_client adapter exposes provider callbacks" do
    assert Code.ensure_loaded?(AcmeClient)
    assert function_exported?(AcmeClient, :order_certificate, 2)
    assert function_exported?(AcmeClient, :renew_certificate, 2)
    assert function_exported?(AcmeClient, :revoke_certificate, 2)
  end
end
