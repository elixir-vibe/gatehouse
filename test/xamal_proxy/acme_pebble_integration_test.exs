defmodule XamalProxy.ACMEPebbleIntegrationTest do
  use ExUnit.Case, async: false

  alias XamalProxy.ACME.Provider.ExAcme

  @moduletag :pebble
  @directory_url "https://localhost:14000/dir"

  test "issues a certificate against local Pebble" do
    previous_req_options = Application.get_env(:req, :default_options)

    Req.default_options(connect_options: [transport_opts: [verify: :verify_none]])

    on_exit(fn -> restore_req_options(previous_req_options) end)

    wait_for_pebble!()

    assert {:ok, certificate} =
             ExAcme.order_certificate(["example.test"],
               directory_url: @directory_url,
               email: "ops@example.test",
               poll_attempts: 30,
               poll_interval: 250,
               client_name: unique_client_name()
             )

    assert certificate.cert_pem =~ "BEGIN CERTIFICATE"
    assert certificate.key_pem =~ "BEGIN EC PRIVATE KEY"
  end

  defp wait_for_pebble!(attempts \\ 60)
  defp wait_for_pebble!(0), do: flunk("Pebble did not become ready at #{@directory_url}")

  defp wait_for_pebble!(attempts) do
    case Req.get(@directory_url, connect_options: [transport_opts: [verify: :verify_none]]) do
      {:ok, %{status: 200}} ->
        :ok

      _other ->
        Process.sleep(500)
        wait_for_pebble!(attempts - 1)
    end
  end

  defp restore_req_options(nil), do: Application.delete_env(:req, :default_options)
  defp restore_req_options(options), do: Application.put_env(:req, :default_options, options)

  defp unique_client_name do
    String.to_atom("xamal_proxy_pebble_#{System.unique_integer([:positive])}")
  end
end
