defmodule XamalProxy.SafeRPCHTTPTest do
  use ExUnit.Case, async: true

  alias SafeRPC.Adapter.HTTP.{Request, Response}
  alias XamalProxy.SafeRPC.HTTP

  test "converts livery requests to SafeRPC HTTP envelopes" do
    request =
      :livery_req.new(%{
        method: "POST",
        scheme: "https",
        authority: "example.com",
        path: "/submit",
        raw_query: "a=1",
        headers: [{"host", "example.com"}, {"content-type", "text/plain"}],
        body: {:buffered, "hello"}
      })

    assert %Request{
             method: "POST",
             scheme: "https",
             host: "example.com",
             port: 443,
             path: "/submit",
             query: "a=1",
             headers: [{"host", "example.com"}, {"content-type", "text/plain"}],
             body: {:full, "hello"}
           } = HTTP.from_livery(request, scheme: :https)
  end

  test "converts SafeRPC HTTP envelopes to livery responses" do
    response =
      HTTP.to_livery(%Response{
        status: 201,
        headers: [{"x-test", "ok"}],
        body: {:full, "created"}
      })

    assert XamalProxy.Livery.Response.status(response) == 201
    assert XamalProxy.Livery.Response.body(response) == {:full, "created"}
  end
end
