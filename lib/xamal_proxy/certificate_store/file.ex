defmodule XamalProxy.CertificateStore.File do
  @moduledoc """
  Filesystem-backed certificate store.
  """

  @behaviour XamalProxy.CertificateStore

  @impl XamalProxy.CertificateStore
  def get(name, opts) when is_binary(name) do
    directory = Keyword.fetch!(opts, :directory)
    cert_path = Path.join(directory, "#{name}.crt")
    key_path = Path.join(directory, "#{name}.key")

    with {:ok, cert} <- File.read(cert_path),
         {:ok, key} <- File.read(key_path) do
      {:ok, %{cert: cert, key: key}}
    end
  end

  @impl XamalProxy.CertificateStore
  def put(name, %{cert: cert, key: key}, opts) when is_binary(name) do
    directory = Keyword.fetch!(opts, :directory)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(Path.join(directory, "#{name}.crt"), cert) do
      File.write(Path.join(directory, "#{name}.key"), key)
    end
  end
end
