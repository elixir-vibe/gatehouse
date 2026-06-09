defmodule XamalProxy.ACMEPebbleIntegrationTest do
  use ExUnit.Case, async: false

  alias XamalProxy.ACME.Provider.ExAcme

  @moduletag :pebble
  @pebble_image "ghcr.io/letsencrypt/pebble:latest"
  @directory_url "https://localhost:14000/dir"

  test "issues a certificate against local Pebble" do
    previous_req_options = Application.get_env(:req, :default_options)

    Req.default_options(connect_options: [transport_opts: [verify: :verify_none]])

    container = ensure_pebble!()

    on_exit(fn ->
      restore_req_options(previous_req_options)
      stop_pebble(container)
    end)

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

  defp ensure_pebble! do
    if System.get_env("XAMAL_PROXY_PEBBLE_EXTERNAL") == "1" do
      wait_for_pebble!()
      :external
    else
      start_pebble_container!()
    end
  end

  defp start_pebble_container! do
    name = "xamal-proxy-pebble-#{System.unique_integer([:positive])}"

    case System.cmd(
           "docker",
           [
             "run",
             "--rm",
             "-d",
             "--name",
             name,
             "-p",
             "127.0.0.1:14000:14000",
             "-e",
             "PEBBLE_VA_ALWAYS_VALID=1",
             "-e",
             "PEBBLE_VA_NOSLEEP=1",
             @pebble_image,
             "-strict",
             "false"
           ],
           stderr_to_stdout: true
         ) do
      {container, 0} ->
        wait_for_pebble!()
        String.trim(container)

      {output, status} ->
        flunk("failed to start Pebble Docker container (status #{status}): #{output}")
    end
  end

  defp wait_for_pebble!(attempts \\ 60)
  defp wait_for_pebble!(0), do: flunk("Pebble did not become ready")

  defp wait_for_pebble!(attempts) do
    case Req.get(@directory_url, connect_options: [transport_opts: [verify: :verify_none]]) do
      {:ok, %{status: 200}} ->
        :ok

      _other ->
        Process.sleep(500)
        wait_for_pebble!(attempts - 1)
    end
  end

  defp stop_pebble(:external), do: :ok

  defp stop_pebble(container),
    do: System.cmd("docker", ["stop", container], stderr_to_stdout: true)

  defp restore_req_options(nil), do: Application.delete_env(:req, :default_options)
  defp restore_req_options(options), do: Application.put_env(:req, :default_options, options)

  defp unique_client_name do
    String.to_atom("xamal_proxy_pebble_#{System.unique_integer([:positive])}")
  end
end
