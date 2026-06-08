defmodule XamalProxy.Livery do
  @moduledoc """
  Small Elixir facade over Livery's Erlang API.
  """

  def start_service(opts), do: :livery.start_service(opts)
  def stop_service(pid), do: :livery.stop_service(pid)
  def listeners(pid), do: :livery.which_listeners(pid)
end
