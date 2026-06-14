defmodule Gatehouse.LiveryListenerTest do
  use ExUnit.Case, async: false

  alias Gatehouse.Config.Listener
  alias Gatehouse.LiveryListener
  alias Gatehouse.TLS.SNI

  test "refresh_tls restarts listener with current options" do
    {:ok, listener} = LiveryListener.start_link(port: 0, name: unique_name())

    assert is_integer(LiveryListener.port(listener))
    assert :ok = LiveryListener.refresh_tls(listener)
    assert is_integer(LiveryListener.port(listener))
  end

  test "HTTPS listener selects certificates by SNI" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "gatehouse-listener-sni-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)

    try do
      {default_cert, default_key} = generate_cert!(directory, "alpha.test", 1001)
      generate_cert!(directory, "beta.test", 1002)

      listener = %Listener{
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        cert_path: default_cert,
        key_path: default_key,
        ssl_opts: SNI.ssl_opts(cert_directory: directory)
      }

      {:ok, server} =
        LiveryListener.start_link(listeners: [listener], name: unique_name())

      {:ok, socket} =
        :ssl.connect(
          ~c"127.0.0.1",
          LiveryListener.port(server),
          ssl_opts(~c"beta.test"),
          5_000
        )

      {:ok, peer_cert} = :ssl.peercert(socket)

      assert certificate_serial(peer_cert) == 1002

      :ssl.close(socket)
    after
      File.rm_rf!(directory)
    end
  end

  defp unique_name do
    String.to_atom("livery_listener_#{System.unique_integer([:positive])}")
  end

  defp generate_cert!(directory, name, serial) do
    cert_path = Path.join(directory, "#{name}.crt")
    key_path = Path.join(directory, "#{name}.key")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-set_serial",
          Integer.to_string(serial),
          "-subj",
          "/CN=#{name}",
          "-addext",
          "subjectAltName=DNS:#{name}",
          "-keyout",
          key_path,
          "-out",
          cert_path
        ],
        stderr_to_stdout: true
      )

    {cert_path, key_path}
  end

  defp ssl_opts(server_name) do
    [verify: :verify_none, server_name_indication: server_name]
  end

  defp certificate_serial(der) do
    {:Certificate, tbs_certificate, _signature_algorithm, _signature} =
      :public_key.pkix_decode_cert(der, :plain)

    elem(tbs_certificate, 2)
  end
end
