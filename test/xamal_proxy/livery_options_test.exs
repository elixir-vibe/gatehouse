defmodule XamalProxy.LiveryOptionsTest do
  use ExUnit.Case, async: true

  alias XamalProxy.Config.Listener

  test "builds HTTP and HTTPS listener options from DSL listener structs" do
    listeners = [
      %Listener{scheme: :http, ip: {127, 0, 0, 1}, port: 8080},
      %Listener{scheme: :https, ip: {127, 0, 0, 1}, port: 8443, cert: "CERT", key: "KEY"}
    ]

    opts =
      listeners
      |> XamalProxy.LiveryOptions.from_config_listeners()
      |> Enum.reduce(%{handler: &XamalProxy.LiveryHandler.handle/1}, fn listener, acc ->
        Map.put(acc, listener.scheme, Map.delete(listener, :scheme))
      end)

    assert opts.http.port == 8080
    assert opts.https.port == 8443
    assert opts.https.cert == "CERT"
    assert opts.https.key == "KEY"
  end
end
