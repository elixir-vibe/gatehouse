defmodule XamalProxy.Target do
  @moduledoc """
  Backend target served by the proxy for a service.
  """

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :url,
    :socket,
    op: :http_request,
    shards: 1,
    kind: :http,
    drain_deadline: nil,
    metadata: %{},
    active_requests: 0,
    draining?: false
  ]

  @type kind :: :http | :safe_rpc

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          url: URI.t() | nil,
          socket: String.t() | nil,
          op: atom(),
          shards: pos_integer(),
          drain_deadline: DateTime.t() | nil,
          metadata: map(),
          active_requests: non_neg_integer(),
          draining?: boolean()
        }

  @spec new(String.t(), String.t() | nil, map()) :: {:ok, t()} | {:error, term()}
  def new(id, url, metadata \\ %{}) when is_binary(id) and is_map(metadata) do
    kind = Map.get(metadata, :kind, :http)

    case kind do
      :http -> new_http(id, url, metadata)
      :safe_rpc -> new_safe_rpc(id, metadata)
    end
  end

  defp new_http(id, url, metadata) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, %__MODULE__{id: id, kind: :http, url: uri, metadata: metadata}}

      {:ok, _uri} ->
        {:error, {:invalid_target_url, url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new_http(_id, url, _metadata), do: {:error, {:invalid_target_url, url}}

  defp new_safe_rpc(id, metadata) do
    case Map.fetch(metadata, :socket) do
      {:ok, socket} when is_binary(socket) ->
        {:ok,
         %__MODULE__{
           id: id,
           kind: :safe_rpc,
           socket: socket,
           op: Map.get(metadata, :op, :http_request),
           shards: Map.get(metadata, :shards, 1),
           metadata: metadata
         }}

      _missing ->
        {:error, :missing_safe_rpc_socket}
    end
  end
end
