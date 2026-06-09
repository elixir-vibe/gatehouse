defmodule XamalProxy.CertificateStore.File do
  @moduledoc """
  Filesystem-backed certificate store.
  """

  @behaviour XamalProxy.CertificateStore

  alias XamalProxy.Certificate.PEM

  @impl XamalProxy.CertificateStore
  def get(name, opts) when is_binary(name) do
    directory = Keyword.fetch!(opts, :directory)
    cert_path = Path.join(directory, "#{name}.crt")
    key_path = Path.join(directory, "#{name}.key")

    with {:ok, cert} <- File.read(cert_path),
         {:ok, key} <- File.read(key_path) do
      {:ok,
       Map.merge(read_metadata(directory, name), certificate_metadata(cert), fn _key, _old, new ->
         new
       end)
       |> Map.merge(%{cert: cert, key: key})}
    end
  end

  @impl XamalProxy.CertificateStore
  def put(name, cert, opts) when is_binary(name) and is_map(cert) do
    directory = Keyword.fetch!(opts, :directory)
    cert_pem = Map.get(cert, :cert) || Map.fetch!(cert, :cert_pem)
    key_pem = Map.get(cert, :key) || Map.fetch!(cert, :key_pem)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(Path.join(directory, "#{name}.crt"), cert_pem),
         :ok <- File.write(Path.join(directory, "#{name}.key"), key_pem) do
      write_metadata(directory, name, Map.drop(cert, [:cert, :key, :cert_pem, :key_pem]))
    end
  end

  defp certificate_metadata(cert) do
    case PEM.metadata(cert) do
      {:ok, metadata} -> metadata
      {:error, _reason} -> %{}
    end
  end

  defp read_metadata(directory, name) do
    path = metadata_path(directory, name)

    case File.read(path) do
      {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
      {:error, _reason} -> %{}
    end
  end

  defp write_metadata(_directory, _name, metadata) when metadata == %{}, do: :ok

  defp write_metadata(directory, name, metadata) do
    File.write(metadata_path(directory, name), :erlang.term_to_binary(metadata))
  end

  defp metadata_path(directory, name), do: Path.join(directory, "#{name}.term")
end
