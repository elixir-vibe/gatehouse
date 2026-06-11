defmodule XamalProxy.ACMERenewalSchedulerTest do
  use ExUnit.Case, async: false

  alias XamalProxy.ACME.RenewalScheduler
  alias XamalProxy.CertificateStore.File, as: FileStore
  alias XamalProxy.Test.FakeACMEProvider

  test "renews missing certificates and persists them" do
    directory =
      Path.join(System.tmp_dir!(), "xamal-proxy-renew-#{System.unique_integer([:positive])}")

    Application.put_env(:xamal_proxy, :acme_certificates, [
      %{
        name: "example.com",
        domains: ["example.com", "www.example.com"],
        provider: FakeACMEProvider,
        provider_opts: [test_pid: self()],
        store: FileStore,
        store_opts: [directory: directory]
      }
    ])

    assert [{"example.com", :ok}] = RenewalScheduler.renew_now()
    assert_receive {:ordered, ["example.com", "www.example.com"]}
    assert {:ok, cert} = FileStore.get("example.com", directory: directory)
    assert cert.cert == "CERT example.com,www.example.com"
    assert cert.key == "KEY"
    assert %DateTime{} = cert.expires_at
    assert {:ok, alias_cert} = FileStore.get("www.example.com", directory: directory)
    assert alias_cert.cert == cert.cert

    File.rm_rf!(directory)
  after
    Application.delete_env(:xamal_proxy, :acme_certificates)
  end

  test "skips certificates that are not due" do
    directory =
      Path.join(System.tmp_dir!(), "xamal-proxy-skip-#{System.unique_integer([:positive])}")

    :ok =
      FileStore.put(
        "example.com",
        %{
          cert_pem: "CERT",
          key_pem: "KEY",
          expires_at: DateTime.add(DateTime.utc_now(), 90, :day)
        },
        directory: directory
      )

    Application.put_env(:xamal_proxy, :acme_certificates, [
      %{
        name: "example.com",
        domains: ["example.com"],
        provider: FakeACMEProvider,
        provider_opts: [test_pid: self()],
        store: FileStore,
        store_opts: [directory: directory],
        renew_before_days: 30
      }
    ])

    assert [{"example.com", {:skip, :not_due}}] = RenewalScheduler.renew_now()
    refute_receive {:ordered, _domains}

    File.rm_rf!(directory)
  after
    Application.delete_env(:xamal_proxy, :acme_certificates)
  end
end
