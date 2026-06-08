defmodule XamalProxy.Livery.Response do
  @moduledoc false

  def text(status, body), do: :livery_resp.text(status, body)
  def new(status, headers, body), do: :livery_resp.new(status, headers, body)
  def stream(status, headers, producer), do: :livery_resp.stream(status, headers, producer)
  def status(response), do: :livery_resp.status(response)
  def body(response), do: :livery_resp.body(response)
  def with_body(body, response), do: :livery_resp.with_body(body, response)
end
