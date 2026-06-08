defmodule XamalProxy.Livery.Body do
  @moduledoc """
  Elixir-facing streaming body helpers over `:livery_body`.
  """

  @type reader :: term()

  @spec read(reader(), timeout()) ::
          {:ok, binary(), reader()} | {:done, reader()} | {:error, term(), reader()}
  def read(reader, timeout), do: :livery_body.read(reader, timeout)

  @spec read_all(reader(), timeout()) :: {:ok, binary(), reader()} | {:error, term(), reader()}
  def read_all(reader, timeout), do: :livery_body.read_all(reader, timeout)
end
