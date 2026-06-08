defmodule XamalProxy.Livery.Body do
  @moduledoc false

  def read(reader, timeout), do: :livery_body.read(reader, timeout)
  def read_all(reader, timeout), do: :livery_body.read_all(reader, timeout)
end
