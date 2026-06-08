defmodule XamalProxy.Config.Target do
  @moduledoc """
  Static backend target configuration.
  """

  @enforce_keys [:name, :url]
  defstruct [:name, :url, active?: false, metadata: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          active?: boolean(),
          metadata: map()
        }
end
