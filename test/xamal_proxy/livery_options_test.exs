defmodule XamalProxy.LiveryOptionsTest do
  use ExUnit.Case, async: true

  alias XamalProxy.CertificateStore.File, as: FileStore
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

  test "adds ACME SNI lookup to HTTPS listeners for auto TLS services" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "xamal-proxy-livery-acme-sni-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "fallback.crt"), "FALLBACK CERT")
    File.write!(Path.join(directory, "fallback.key"), "FALLBACK KEY")

    :ok =
      FileStore.put(
        "example.com",
        %{cert: "CERT", key: "KEY", domains: ["example.com", "www.example.com"]},
        directory: directory
      )

    config =
      XamalProxy.Config.eval!("""
      import XamalProxy.Config
      acme cert_directory: #{inspect(directory)}
      https port: 8443, cert: #{inspect(Path.join(directory, "fallback.crt"))}, key: #{inspect(Path.join(directory, "fallback.key"))}
      service :web do
        host "example.com"
        host "www.example.com"
        tls :auto
        target :blue, "http://127.0.0.1:4000", active: true
      end
      """)

    assert [%{scheme: :https, ssl_opts: ssl_opts}] = XamalProxy.LiveryOptions.from_config(config)
    assert [{:sni_fun, sni_fun}] = ssl_opts

    assert sni_fun.(~c"www.example.com") == [
             certfile: Path.join(directory, "example.com.crt"),
             keyfile: Path.join(directory, "example.com.key")
           ]

    File.rm_rf!(directory)
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
