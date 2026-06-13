defmodule XamalProxy.Config.Target do
  @moduledoc """
  Static backend target configuration.
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    :url,
    kind: :http,
    socket: nil,
    op: :http_request,
    shards: 1,
    active?: false,
    metadata: %{}
  ]

  @type kind :: :http | :safe_rpc

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t() | nil,
          kind: kind(),
          socket: String.t() | nil,
          op: atom(),
          shards: pos_integer(),
          active?: boolean(),
          metadata: map()
        }
end
