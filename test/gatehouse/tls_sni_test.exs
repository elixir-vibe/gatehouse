defmodule Gatehouse.TLS.SNITest do
  use ExUnit.Case, async: true

  alias Gatehouse.CertificateStore.File, as: FileStore
  alias Gatehouse.TLS.SNI

  test "builds ssl sni_fun options backed by certificate directory" do
    directory =
      Path.join(System.tmp_dir!(), "gatehouse-sni-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    :ok =
      FileStore.put(
        "example.com",
        %{cert: "CERT", key: "KEY", domains: ["example.com", "www.example.com"]},
        directory: directory
      )

    assert [{:sni_fun, sni_fun}] = SNI.ssl_opts(cert_directory: directory)

    assert sni_fun.(~c"Example.COM.") == [
             certfile: Path.join(directory, "example.com.crt"),
             keyfile: Path.join(directory, "example.com.key")
           ]

    assert sni_fun.(~c"www.example.com") == [
             certfile: Path.join(directory, "example.com.crt"),
             keyfile: Path.join(directory, "example.com.key")
           ]

    assert sni_fun.(~c"missing.example") == []

    File.rm_rf!(directory)
  end
end
