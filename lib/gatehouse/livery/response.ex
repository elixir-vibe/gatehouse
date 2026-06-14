defmodule Gatehouse.Livery.Response do
  @moduledoc """
  Elixir-facing response helpers over `:livery_resp`.
  """

  @type t :: term()
  @type body :: {:full, iodata()} | {:chunked, function()} | {:sse, function()} | :empty | term()
  @type header :: {binary(), binary()}

  @spec text(pos_integer(), iodata()) :: t()
  def text(status, body), do: :livery_resp.text(status, body)

  @spec new(pos_integer(), [header()], body()) :: t()
  def new(status, headers, body), do: :livery_resp.new(status, headers, body)

  @spec stream(pos_integer(), [header()], function()) :: t()
  def stream(status, headers, producer), do: :livery_resp.stream(status, headers, producer)

  @spec status(t()) :: pos_integer()
  def status(response), do: :livery_resp.status(response)

  @spec body(t()) :: body()
  def body(response), do: :livery_resp.body(response)

  @spec with_body(body(), t()) :: t()
  def with_body(body, response), do: :livery_resp.with_body(body, response)
end
