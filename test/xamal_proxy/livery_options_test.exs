defmodule XamalProxy.LiveryOptionsTest do
  use ExUnit.Case, async: true

  alias XamalProxy.Config.Listener

  test "builds HTTP and HTTPS listener options from DSL listener structs" do
    listeners = [
      %Listener{scheme: :http, ip: {127, 0, 0, 1}, port: 8080},
      %Listener{
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 8443,
        cert: "CERT",
        key: "KEY",
        ssl_opts: [{:sni_fun, fn _ -> [] end}]
      }
    ]

    opts =
      listeners
      |> XamalProxy.LiveryOptions.from_config_listeners()
      |> Enum.reduce(%{handler: &XamalProxy.LiveryHandler.handle/1}, fn listener, acc ->
        Map.put(acc, listener.scheme, Map.delete(listener, :scheme))
      end)

    assert opts.http.port == 8080
    assert opts.https.port == 8443
    assert opts.https.cert == "CERT"
    assert opts.https.key == "KEY"
    assert Keyword.has_key?(opts.https.ssl_opts, :sni_fun)
  end

  test "uses TLS certificate file paths when building options" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "xamal-proxy-livery-options-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    cert_path = Path.join(directory, "cert.pem")
    key_path = Path.join(directory, "key.pem")
    File.write!(cert_path, "CERT1")
    File.write!(key_path, "KEY1")

    listener = %Listener{
      scheme: :https,
      ip: {127, 0, 0, 1},
      port: 8443,
      cert_path: cert_path,
      key_path: key_path
    }

    assert [opts] = XamalProxy.LiveryOptions.from_config_listeners([listener])
    assert opts.cert == cert_path
    assert opts.key == key_path

    File.rm_rf!(directory)
  end
end
