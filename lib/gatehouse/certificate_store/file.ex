defmodule Gatehouse.CertificateStore.File do
  @moduledoc """
  Filesystem-backed certificate store.
  """

  @behaviour Gatehouse.CertificateStore

  alias Gatehouse.Certificate.PEM

  @spec paths(String.t(), keyword()) ::
          {:ok, %{certfile: Path.t(), keyfile: Path.t()}} | {:error, term()}
  def paths(name, opts) when is_binary(name) do
    directory = Keyword.fetch!(opts, :directory)

    with {:ok, canonical_name} <- resolve_name(directory, name) do
      paths = certificate_paths(directory, canonical_name)

      if File.regular?(paths.certfile) and File.regular?(paths.keyfile) do
        {:ok, paths}
      else
        {:error, :enoent}
      end
    end
  end

  @impl Gatehouse.CertificateStore
  def get(name, opts) when is_binary(name) do
    directory = Keyword.fetch!(opts, :directory)

    with {:ok, canonical_name} <- resolve_name(directory, name),
         %{certfile: cert_path, keyfile: key_path} <- certificate_paths(directory, canonical_name),
         {:ok, cert} <- File.read(cert_path),
         {:ok, key} <- File.read(key_path) do
      {:ok,
       Map.merge(read_metadata(directory, canonical_name), certificate_metadata(cert), fn _key,
                                                                                          _old,
                                                                                          new ->
         new
       end)
       |> Map.merge(%{cert: cert, key: key})}
    end
  end

  @impl Gatehouse.CertificateStore
  def put(name, cert, opts) when is_binary(name) and is_map(cert) do
    directory = Keyword.fetch!(opts, :directory)
    cert_pem = Map.get(cert, :cert) || Map.fetch!(cert, :cert_pem)
    key_pem = Map.get(cert, :key) || Map.fetch!(cert, :key_pem)

    name = normalize_name(name)
    paths = certificate_paths(directory, name)
    metadata = Map.drop(cert, [:cert, :key, :cert_pem, :key_pem])

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(paths.certfile, cert_pem),
         :ok <- File.write(paths.keyfile, key_pem),
         :ok <- write_metadata(directory, name, metadata) do
      write_aliases(directory, name, Map.get(metadata, :domains, []))
    end
  end

  defp certificate_metadata(cert) do
    case PEM.metadata(cert) do
      {:ok, metadata} -> metadata
      {:error, _reason} -> %{}
    end
  end

  defp read_metadata(directory, name) do
    case read_term(metadata_path(directory, normalize_name(name))) do
      {:ok, metadata} -> metadata
      {:error, _reason} -> %{}
    end
  end

  defp resolve_name(directory, name) do
    name = normalize_name(name)

    if certificate_files?(directory, name) do
      {:ok, name}
    else
      case read_term(metadata_path(directory, name)) do
        {:ok, %{alias_for: canonical_name}} -> {:ok, canonical_name}
        {:ok, %{"alias_for" => canonical_name}} -> {:ok, canonical_name}
        {:ok, _metadata} -> {:ok, name}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_term(path) do
    with {:ok, binary} <- File.read(path) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    ArgumentError -> {:error, :invalid_metadata}
  end

  defp certificate_files?(directory, name) do
    %{certfile: certfile, keyfile: keyfile} = certificate_paths(directory, name)
    File.regular?(certfile) and File.regular?(keyfile)
  end

  defp write_metadata(_directory, _name, metadata) when metadata == %{}, do: :ok

  defp write_metadata(directory, name, metadata) do
    File.write(metadata_path(directory, name), :erlang.term_to_binary(metadata))
  end

  defp write_aliases(directory, canonical_name, domains) do
    domains
    |> Enum.map(&normalize_name/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == canonical_name))
    |> Enum.reduce_while(:ok, fn alias_name, :ok ->
      case write_metadata(directory, alias_name, %{alias_for: canonical_name}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp certificate_paths(directory, name) do
    name = normalize_name(name)
    %{certfile: Path.join(directory, "#{name}.crt"), keyfile: Path.join(directory, "#{name}.key")}
  end

  defp metadata_path(directory, name), do: Path.join(directory, "#{normalize_name(name)}.term")

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim_trailing(".")
    |> String.downcase()
  end
end
