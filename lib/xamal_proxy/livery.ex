defmodule XamalProxy.Livery do
  @moduledoc """
  Small Elixir facade over Livery's Erlang API.
  """

  @type service :: pid()

  @spec start_service(map()) :: {:ok, service()} | {:error, term()}
  def start_service(opts), do: :livery.start_service(opts)

  @spec stop_service(service()) :: :ok
  def stop_service(pid), do: :livery.stop_service(pid)

  @spec listeners(service()) :: map()
  def listeners(pid), do: :livery.which_listeners(pid)
end
