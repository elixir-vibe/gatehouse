defmodule XamalProxy.AcmeProviderTest do
  use ExUnit.Case, async: true

  alias XamalProxy.Acme.Provider.AcmeClient

  test "acme_client adapter is an explicit prototype" do
    assert {:error, {:not_implemented, :acme_client_adapter}} =
             AcmeClient.order_certificate(["example.com"], [])
  end
end
