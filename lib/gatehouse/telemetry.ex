defmodule Gatehouse.Telemetry do
  @moduledoc """
  Thin telemetry wrapper for proxy lifecycle and request events.
  """

  @prefix [:gatehouse]

  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) do
    :telemetry.execute(@prefix ++ event, measurements, metadata)
  end
end
