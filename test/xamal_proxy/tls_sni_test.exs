defmodule XamalProxy.TLS.SNITest do
  use ExUnit.Case, async: true

  alias XamalProxy.TLS.SNI

  test "builds ssl sni_fun options backed by certificate directory" do
    directory =
      Path.join(System.tmp_dir!(), "xamal-proxy-sni-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "example.com.crt"), "CERT")
    File.write!(Path.join(directory, "example.com.key"), "KEY")

    assert [{:sni_fun, sni_fun}] = SNI.ssl_opts(cert_directory: directory)

    assert sni_fun.(~c"Example.COM.") == [
             certfile: Path.join(directory, "example.com.crt"),
             keyfile: Path.join(directory, "example.com.key")
           ]

    assert sni_fun.(~c"missing.example") == []

    File.rm_rf!(directory)
  end
end
