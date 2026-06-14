defmodule Gatehouse.Test.FakeACMEProvider do
  @moduledoc false

  @behaviour Gatehouse.ACME.Provider

  @impl Gatehouse.ACME.Provider
  def order_certificate(domains, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:ordered, domains})

    {:ok,
     %{
       cert_pem: "CERT #{Enum.join(domains, ",")}",
       key_pem: "KEY",
       expires_at: DateTime.add(DateTime.utc_now(), 90, :day)
     }}
  end

  @impl Gatehouse.ACME.Provider
  def renew_certificate(certificate, _opts), do: {:ok, certificate}

  @impl Gatehouse.ACME.Provider
  def revoke_certificate(_certificate, _opts), do: :ok
end
