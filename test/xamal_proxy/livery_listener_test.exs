defmodule XamalProxy.LiveryListenerTest do
  use ExUnit.Case, async: false

  test "refresh_tls restarts listener with current options" do
    {:ok, listener} = XamalProxy.LiveryListener.start_link(port: 0, name: unique_name())

    assert is_integer(XamalProxy.LiveryListener.port(listener))
    assert :ok = XamalProxy.LiveryListener.refresh_tls(listener)
    assert is_integer(XamalProxy.LiveryListener.port(listener))
  end

  defp unique_name do
    String.to_atom("livery_listener_#{System.unique_integer([:positive])}")
  end
end
