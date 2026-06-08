defmodule DemoApp.WebSocketEcho do
  @moduledoc false

  @behaviour :ws_handler

  def init(_request, _opts), do: {:ok, nil}

  def handle_in({:text, data}, state), do: {:reply, [{:text, data}], state}
  def handle_in({:binary, data}, state), do: {:reply, [{:binary, data}], state}
  def handle_in({:ping, data}, state), do: {:reply, [{:pong, data}], state}
  def handle_in({:close, code, _reason}, state), do: {:stop, {:peer_closed, code}, state}
  def handle_in(_frame, state), do: {:ok, state}

  def handle_info(_message, state), do: {:ok, state}
  def terminate(_reason, _state), do: :ok
end
