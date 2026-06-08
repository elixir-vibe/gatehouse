defmodule XamalProxy.Backend.Response do
  @moduledoc false

  @enforce_keys [:status, :headers, :body]
  defstruct [:status, :headers, :body]

  @type t :: %__MODULE__{status: pos_integer(), headers: [{binary(), binary()}], body: binary()}
end
