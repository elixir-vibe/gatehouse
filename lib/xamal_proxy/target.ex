defmodule XamalProxy.Target do
  @moduledoc """
  Backend target served by the proxy for a service.
  """

  @enforce_keys [:id, :url]
  defstruct [:id, :url, :drain_deadline, metadata: %{}, active_requests: 0, draining?: false]

  @type t :: %__MODULE__{
          id: String.t(),
          url: URI.t(),
          drain_deadline: DateTime.t() | nil,
          metadata: map(),
          active_requests: non_neg_integer(),
          draining?: boolean()
        }

  @spec new(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def new(id, url, metadata \\ %{}) when is_binary(id) and is_binary(url) and is_map(metadata) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, %__MODULE__{id: id, url: uri, metadata: metadata}}

      {:ok, _uri} ->
        {:error, {:invalid_target_url, url}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
