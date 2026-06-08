defmodule XamalProxy.Livery.WebSocket do
  @moduledoc false

  def upgrade(request, handler, opts), do: :livery_ws.upgrade(request, handler, opts)
end
