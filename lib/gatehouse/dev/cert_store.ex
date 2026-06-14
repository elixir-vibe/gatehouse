defmodule Gatehouse.Dev.CertStore do
  @moduledoc """
  Local development certificate authority for Gatehouse mix tasks.

  Certificates are stored under `~/.gatehouse/dev_certs` by default. The CA is
  intentionally local-development only and is never used by Gatehouse runtime
  ACME flows.
  """

  alias X509.{Certificate, PrivateKey, PublicKey}
  alias X509.Certificate.Extension

  @ca_days round(10 * 365.2425)
  @server_days 395

  @type server_cert :: %{cert_path: Path.t(), key_path: Path.t(), ca_cert_path: Path.t()}

  @spec default_dir() :: Path.t()
  def default_dir do
    Path.join(System.user_home!(), ".gatehouse/dev_certs")
  end

  @spec ca_cert_path(Path.t()) :: Path.t()
  def ca_cert_path(dir \\ default_dir()), do: Path.join(dir, "gatehouse-dev-ca.pem")

  @spec ensure_ca(Path.t()) ::
          {:ok, %{cert_path: Path.t(), key_path: Path.t()}} | {:error, term()}
  def ensure_ca(dir \\ default_dir()) do
    with :ok <- File.mkdir_p(dir),
         :ok <- ensure_ca_files(dir) do
      {:ok, %{cert_path: ca_cert_path(dir), key_path: ca_key_path(dir)}}
    end
  end

  @spec ensure_server_cert(String.t(), Path.t()) :: {:ok, server_cert()} | {:error, term()}
  def ensure_server_cert(host, dir \\ default_dir()) when is_binary(host) do
    with {:ok, _ca} <- ensure_ca(dir),
         :ok <- File.mkdir_p(host_dir(dir, host)),
         :ok <- ensure_host_files(dir, host) do
      {:ok,
       %{
         cert_path: host_cert_path(dir, host),
         key_path: host_key_path(dir, host),
         ca_cert_path: ca_cert_path(dir)
       }}
    end
  end

  defp ensure_ca_files(dir) do
    cert_path = ca_cert_path(dir)
    key_path = ca_key_path(dir)

    if File.exists?(cert_path) and File.exists?(key_path) do
      :ok
    else
      key = PrivateKey.new_ec(:secp256r1)

      cert =
        Certificate.self_signed(key, "/CN=Gatehouse Dev Local CA",
          template: :root_ca,
          validity: @ca_days
        )

      :ok = write_private(key_path, PrivateKey.to_pem(key))
      File.write(cert_path, Certificate.to_pem(cert))
    end
  end

  defp ensure_host_files(dir, host) do
    cert_path = host_cert_path(dir, host)
    key_path = host_key_path(dir, host)

    if File.exists?(cert_path) and File.exists?(key_path) do
      :ok
    else
      ca_key = read_private_key!(ca_key_path(dir))
      ca_cert = read_certificate!(ca_cert_path(dir))
      key = PrivateKey.new_ec(:secp256r1)
      sans = host_sans(host)

      cert =
        key
        |> PublicKey.derive()
        |> Certificate.new("/CN=#{host}", ca_cert, ca_key,
          template: :server,
          validity: @server_days,
          extensions: [subject_alt_name: Extension.subject_alt_name(sans)]
        )

      :ok = write_private(key_path, PrivateKey.to_pem(key))
      File.write(cert_path, Certificate.to_pem(cert))
    end
  end

  defp host_sans(host) do
    [host, "localhost"]
    |> Enum.concat(localhost_parent(host))
    |> Enum.uniq()
  end

  defp localhost_parent(host) do
    case String.split(host, ".") do
      [_left, "localhost"] -> ["localhost"]
      _other -> []
    end
  end

  defp read_private_key!(path) do
    path
    |> File.read!()
    |> PrivateKey.from_pem!()
  end

  defp read_certificate!(path) do
    path
    |> File.read!()
    |> Certificate.from_pem!()
  end

  defp write_private(path, pem) do
    with :ok <- File.write(path, pem) do
      File.chmod(path, 0o600)
    end
  end

  defp ca_key_path(dir), do: Path.join(dir, "gatehouse-dev-ca-key.pem")

  defp host_dir(dir, host), do: Path.join(dir, safe_host(host))
  defp host_cert_path(dir, host), do: Path.join(host_dir(dir, host), "cert.pem")
  defp host_key_path(dir, host), do: Path.join(host_dir(dir, host), "key.pem")

  defp safe_host(host) do
    String.replace(host, ~r/[^A-Za-z0-9_.-]/, "_")
  end
end
