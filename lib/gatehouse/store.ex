defmodule Gatehouse.Store do
  @moduledoc """
  Atomic ETF persistence helpers for route state snapshots.

  This is intentionally boring for the first release: one local file, encoded
  with `:erlang.term_to_binary/1`, written through a temporary file and rename.
  """

  @spec load(Path.t()) :: {:ok, term()} | {:error, :enoent | term()}
  def load(path) do
    with {:ok, binary} <- File.read(path) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  end

  @spec save(Path.t(), term()) :: :ok | {:error, term()}
  def save(path, term) when is_binary(path) do
    tmp_path = path <> ".tmp"
    binary = :erlang.term_to_binary(term)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, binary) do
      File.rename(tmp_path, path)
    end
  end
end
