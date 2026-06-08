defmodule XamalProxy.Livery.Request do
  @moduledoc false

  def method(request), do: :livery_req.method(request)
  def path(request), do: :livery_req.path(request)
  def query(request), do: :livery_req.query(request)
  def body(request), do: :livery_req.body(request)
  def headers(request), do: :livery_req.headers(request)
  def header(request, name, default \\ <<>>), do: :livery_req.header(name, request, default)

  def host(request) do
    request
    |> header(<<"host">>, <<>>)
    |> to_string()
    |> String.split(":", parts: 2)
    |> hd()
  end
end
