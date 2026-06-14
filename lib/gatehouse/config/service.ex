defmodule Gatehouse.Config.Service do
  @moduledoc """
  Static service configuration.
  """

  alias Gatehouse.Config.Target

  @enforce_keys [:name]
  defstruct [
    :name,
    :tls,
    hosts: [],
    targets: [],
    balance: %{policy: :active, options: []},
    health: %{path: "/up", timeout: 5_000, interval: 1_000},
    drain: %{timeout: 30_000}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          hosts: [String.t()],
          targets: [Target.t()],
          balance: %{policy: :active | :round_robin, options: keyword()},
          health: %{path: String.t(), timeout: timeout(), interval: timeout()},
          drain: %{timeout: timeout()},
          tls: :auto | false | keyword() | nil
        }

  @spec active_target(t()) :: Target.t() | nil
  def active_target(%__MODULE__{targets: targets}) do
    Enum.find(targets, & &1.active?)
  end
end
