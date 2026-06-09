defmodule XamalProxy.CertificateStoreTest do
  use ExUnit.Case, async: true

  alias XamalProxy.CertificateStore.File, as: FileStore

  test "file store writes and reads cert material" do
    directory =
      Path.join(System.tmp_dir!(), "xamal-proxy-certs-#{System.unique_integer([:positive])}")

    assert :ok =
             FileStore.put(
               "example.com",
               %{cert: "CERT", key: "KEY"},
               directory: directory
             )

    assert {:ok, %{cert: "CERT", key: "KEY"}} =
             FileStore.get("example.com", directory: directory)

    File.rm_rf!(directory)
  end

  test "derives expiry metadata from persisted certificate PEM" do
    directory =
      Path.join(System.tmp_dir!(), "xamal-proxy-cert-store-#{System.unique_integer([:positive])}")

    cert = first_certifi_certificate()

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "example.com.crt"), cert)
    File.write!(Path.join(directory, "example.com.key"), "KEY")

    assert {:ok, loaded} = FileStore.get("example.com", directory: directory)
    assert %DateTime{} = loaded.expires_at
    assert is_integer(loaded.serial_number)

    File.rm_rf!(directory)
  end

  defp first_certifi_certificate do
    "deps/certifi/priv/cacerts.pem"
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.find(&match?({:Certificate, _der, _params}, &1))
    |> then(&:public_key.pem_encode([&1]))
  end
end
