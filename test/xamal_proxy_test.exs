defmodule XamalProxyTest do
  use ExUnit.Case
  doctest XamalProxy

  test "greets the world" do
    assert XamalProxy.hello() == :world
  end
end
