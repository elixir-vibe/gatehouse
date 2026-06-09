defmodule XamalProxy.Certificate.PEMTest do
  use ExUnit.Case, async: true

  alias XamalProxy.Certificate.PEM

  test "extracts expiry from certificate PEM using OTP public_key" do
    pem = first_certifi_certificate()

    assert {:ok, metadata} = PEM.metadata(pem)
    assert %DateTime{} = metadata.expires_at
    assert is_integer(metadata.serial_number)
  end

  defp first_certifi_certificate do
    "deps/certifi/priv/cacerts.pem"
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.find(&match?({:Certificate, _der, _params}, &1))
    |> then(&:public_key.pem_encode([&1]))
  end
end
