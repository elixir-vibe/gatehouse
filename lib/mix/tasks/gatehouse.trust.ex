defmodule Mix.Tasks.Gatehouse.Trust do
  @moduledoc """
  Creates the Gatehouse local development CA and prints trust-store guidance.

  Gatehouse stores the CA under `~/.gatehouse/dev_certs` by default. This task is
  intentionally conservative: it does not run `sudo` for you, but prints the
  platform command to install the CA when one is known.
  """

  use Mix.Task

  alias Gatehouse.Dev.CertStore

  @shortdoc "Create the local dev CA and show trust-store instructions"

  @switches [cert_dir: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, rest, invalid} = OptionParser.parse(args, switches: @switches)

    if invalid != [], do: Mix.raise("Invalid gatehouse.trust option(s): #{inspect(invalid)}")

    if rest != [],
      do: Mix.raise("Unexpected gatehouse.trust argument(s): #{Enum.join(rest, " ")}")

    cert_dir = opts[:cert_dir] || CertStore.default_dir()
    {:ok, ca} = CertStore.ensure_ca(cert_dir)

    Mix.shell().info("Gatehouse dev CA is ready: #{ca.cert_path}")
    Mix.shell().info(instructions(ca.cert_path))
  end

  defp instructions(ca_path) do
    case :os.type() do
      {:unix, :darwin} ->
        """

        To trust it on macOS:

          sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain #{ca_path}
        """

      {:unix, :linux} ->
        """

        To trust it on Debian/Ubuntu Linux:

          sudo cp #{ca_path} /usr/local/share/ca-certificates/gatehouse-dev-ca.crt
          sudo update-ca-certificates

        On Fedora/RHEL:

          sudo cp #{ca_path} /etc/pki/ca-trust/source/anchors/gatehouse-dev-ca.crt
          sudo update-ca-trust
        """

      _other ->
        """

        Import this CA certificate into your operating system/browser trust store:

          #{ca_path}
        """
    end
  end
end
