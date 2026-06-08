defmodule XamalProxy.ConfigTlsTest do
  use ExUnit.Case, async: true

  test "https directive loads static certificate and key files" do
    directory =
      Path.join(System.tmp_dir!(), "xamal-proxy-tls-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    cert_path = Path.join(directory, "cert.pem")
    key_path = Path.join(directory, "key.pem")
    File.write!(cert_path, "CERT")
    File.write!(key_path, "KEY")

    config =
      XamalProxy.Config.eval!("""
      import XamalProxy.Config
      https port: 8443, cert: #{inspect(cert_path)}, key: #{inspect(key_path)}
      """)

    assert [listener] = config.listeners
    assert listener.scheme == :https
    assert listener.port == 8443
    assert listener.cert == "CERT"
    assert listener.key == "KEY"
    assert listener.cert_path == cert_path
    assert listener.key_path == key_path

    File.rm_rf!(directory)
  end
end
