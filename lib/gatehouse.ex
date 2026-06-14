defmodule Gatehouse do
  @moduledoc """
  OTP-native edge proxy and blue-green traffic switcher for Xamal deployments.

  `Gatehouse` is intended to run as a stable BEAM node at the edge. Xamal can
  start a new application release on an inactive port, then ask this node to
  health-check and atomically switch traffic to the new target over Erlang
  distribution.
  """
end
