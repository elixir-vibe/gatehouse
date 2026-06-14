defmodule Gatehouse.WebSocketProxy do
  @moduledoc """
  WebSocket bridge between Livery inbound sessions and Gun backend sessions.
  """

  @behaviour :ws_handler

  alias Gatehouse.Backend.Connection

  @timeout 5_000

  def init(_request, opts) do
    target_url = Map.fetch!(opts, :target_url)
    path = Map.fetch!(opts, :path)
    headers = Map.get(opts, :headers, [])

    with {:ok, conn} <- open(target_url),
         stream <- :gun.ws_upgrade(conn, path, headers),
         {:upgrade, _protocols, _response_headers} <- :gun.await(conn, stream, @timeout) do
      {:ok, %{conn: conn, stream: stream}}
    else
      {:error, reason} -> {:stop, reason, nil}
      other -> {:stop, {:ws_upgrade_failed, other}, nil}
    end
  end

  def handle_in({:close, _code, _reason} = frame, state) do
    :gun.ws_send(state.conn, state.stream, frame)
    {:stop, :client_closed, state}
  end

  def handle_in(frame, state) do
    :gun.ws_send(state.conn, state.stream, frame)
    {:ok, state}
  end

  def handle_info(
        {:gun_ws, conn, stream, {:close, _code, _reason} = frame},
        %{conn: conn, stream: stream} = state
      ) do
    {:reply, [frame], state}
  end

  def handle_info({:gun_ws, conn, stream, frame}, %{conn: conn, stream: stream} = state) do
    {:reply, [frame], state}
  end

  def handle_info({:gun_error, conn, reason}, %{conn: conn} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state) do
    {:ok, state}
  end

  def terminate(_reason, %{conn: conn}) do
    :gun.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open(%URI{} = uri), do: Connection.open(uri, @timeout)
end
