defmodule XamalProxyTest do
  use ExUnit.Case, async: false

  test "deploy creates a service and switches the route table" do
    spec = %{
      service: "app",
      hosts: ["Example.COM"],
      target_id: "green",
      target_url: "http://127.0.0.1:4001"
    }

    assert {:ok, state} = XamalProxy.Control.deploy(spec)
    assert state.status == :serving
    assert state.active_target.id == "green"
    assert {:ok, "app", "green"} = XamalProxy.RouteTable.lookup("example.com")
  end

  test "a second deploy keeps the old target for future draining" do
    first = %{
      service: "api",
      hosts: ["api.example.com"],
      target_id: "blue",
      target_url: "http://127.0.0.1:5000"
    }

    second = %{first | target_id: "green", target_url: "http://127.0.0.1:5001"}

    assert {:ok, _state} = XamalProxy.Control.deploy(first)
    assert {:ok, state} = XamalProxy.Control.deploy(second)

    assert state.active_target.id == "green"
    assert Map.has_key?(state.old_targets, "blue")
    assert {:ok, "api", "green"} = XamalProxy.RouteTable.lookup("api.example.com")
  end
end
