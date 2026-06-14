defmodule Gatehouse.Service.State do
  @moduledoc """
  Runtime state for one proxied service.
  """

  alias Gatehouse.Target

  @enforce_keys [:id]
  defstruct [
    :id,
    hosts: [],
    active_target: nil,
    active_targets: [],
    target_cursor: 0,
    old_targets: %{},
    status: :empty
  ]

  @type status :: :empty | :serving | :checking | :switching | :draining | :paused | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          hosts: [String.t()],
          active_target: Target.t() | nil,
          active_targets: [Target.t()],
          target_cursor: non_neg_integer(),
          old_targets: %{optional(String.t()) => Target.t()},
          status: status()
        }
end
