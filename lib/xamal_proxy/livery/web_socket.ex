defmodule XamalProxy.Livery.WebSocket do
  @moduledoc """
  Elixir-facing WebSocket upgrade helper over `:livery_ws`.
  """

  @spec upgrade(term(), module(), term()) :: term()
  def upgrade(request, handler, opts), do: :livery_ws.upgrade(request, handler, opts)
end
