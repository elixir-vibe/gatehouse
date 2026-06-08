defmodule XamalProxy.CertificateStoreTest do
  use ExUnit.Case, async: true

  test "file store writes and reads cert material" do
    directory =
      Path.join(System.tmp_dir!(), "xamal-proxy-certs-#{System.unique_integer([:positive])}")

    assert :ok =
             XamalProxy.CertificateStore.File.put(
               "example.com",
               %{cert: "CERT", key: "KEY"},
               directory: directory
             )

    assert {:ok, %{cert: "CERT", key: "KEY"}} =
             XamalProxy.CertificateStore.File.get("example.com", directory: directory)

    File.rm_rf!(directory)
  end
end
