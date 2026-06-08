defmodule XamalProxy.Config.Listener do
  @moduledoc """
  Static listener configuration.
  """

  @enforce_keys [:scheme, :ip, :port]
  defstruct [:scheme, :ip, :port, :cert, :key]

  @type t :: %__MODULE__{
          scheme: :http | :https,
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          cert: binary() | nil,
          key: binary() | nil
        }
end
