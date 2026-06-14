defmodule Gatehouse.Config.Listener do
  @moduledoc """
  Static listener configuration.
  """

  @enforce_keys [:scheme, :ip, :port]
  defstruct [:scheme, :ip, :port, :cert, :key, :cert_path, :key_path, ssl_opts: []]

  @type t :: %__MODULE__{
          scheme: :http | :https,
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          cert: binary() | nil,
          key: binary() | nil,
          cert_path: Path.t() | nil,
          key_path: Path.t() | nil,
          ssl_opts: keyword()
        }
end
