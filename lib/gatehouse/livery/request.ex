defmodule Gatehouse.Livery.Request do
  @moduledoc """
  Elixir-facing request accessors over `:livery_req`.
  """

  @type t :: term()
  @type body :: :empty | {:buffered, iodata()} | {:stream, term()}
  @type header :: {binary(), binary()}

  @spec method(t()) :: binary()
  def method(request), do: :livery_req.method(request)

  @spec path(t()) :: binary()
  def path(request), do: :livery_req.path(request)

  @spec query(t()) :: binary()
  def query(request), do: :livery_req.query(request)

  @spec body(t()) :: body()
  def body(request), do: :livery_req.body(request)

  @spec headers(t()) :: [header()]
  def headers(request), do: :livery_req.headers(request)

  @spec header(t(), binary(), binary()) :: binary()
  def header(request, name, default \\ <<>>), do: :livery_req.header(name, request, default)

  @spec authority(t()) :: binary()
  def authority(request), do: :livery_req.authority(request)

  @spec host(t()) :: String.t()
  def host(request) do
    request
    |> authority_or_host()
    |> to_string()
    |> String.split(":", parts: 2)
    |> hd()
  end

  defp authority_or_host(request) do
    case authority(request) do
      <<>> -> header(request, <<"host">>, <<>>)
      authority -> authority
    end
  end
end
