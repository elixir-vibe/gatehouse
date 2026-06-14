defmodule Gatehouse.CertificateStoreTest do
  use ExUnit.Case, async: true

  alias Gatehouse.CertificateStore.File, as: FileStore

  test "file store writes and reads cert material" do
    directory =
      Path.join(System.tmp_dir!(), "gatehouse-certs-#{System.unique_integer([:positive])}")

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

  test "resolves domain aliases to the canonical certificate" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "gatehouse-cert-aliases-#{System.unique_integer([:positive])}"
      )

    assert :ok =
             FileStore.put(
               "example.com",
               %{cert: "CERT", key: "KEY", domains: ["example.com", "www.example.com"]},
               directory: directory
             )

    assert {:ok, %{certfile: certfile, keyfile: keyfile}} =
             FileStore.paths("www.example.com", directory: directory)

    assert certfile == Path.join(directory, "example.com.crt")
    assert keyfile == Path.join(directory, "example.com.key")

    assert {:ok, %{cert: "CERT", key: "KEY"}} =
             FileStore.get("www.example.com", directory: directory)

    File.rm_rf!(directory)
  end

  test "derives expiry metadata from persisted certificate PEM" do
    directory =
      Path.join(System.tmp_dir!(), "gatehouse-cert-store-#{System.unique_integer([:positive])}")

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
