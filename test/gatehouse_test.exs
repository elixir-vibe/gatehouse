defmodule GatehouseTest do
  use ExUnit.Case, async: false

  test "deploy creates a service and switches the route table" do
    spec = %{
      service: "app",
      hosts: ["Example.COM"],
      target_id: "green",
      target_url: "http://127.0.0.1:4001",
      skip_health_check: true
    }

    assert {:ok, state} = Gatehouse.Control.deploy(spec)
    assert state.status == :serving
    assert state.active_target.id == "green"
    assert {:ok, "app", "green"} = Gatehouse.RouteTable.lookup("example.com")
    assert {:ok, "app", "green", target} = Gatehouse.RouteTable.lookup_target("example.com")
    assert target.id == "green"
  end

  test "a second deploy keeps the old target for future draining" do
    first = %{
      service: "api",
      hosts: ["api.example.com"],
      target_id: "blue",
      target_url: "http://127.0.0.1:5000",
      skip_health_check: true
    }

    second = %{first | target_id: "green", target_url: "http://127.0.0.1:5001"}

    assert {:ok, _state} = Gatehouse.Control.deploy(first)
    assert {:ok, state} = Gatehouse.Control.deploy(second)

    assert state.active_target.id == "green"
    assert Map.has_key?(state.old_targets, "blue")
    assert {:ok, "api", "green"} = Gatehouse.RouteTable.lookup("api.example.com")
  end

  test "deploy refuses to switch when health check fails" do
    first = %{
      service: "health-fail",
      hosts: ["health.example.com"],
      target_id: "blue",
      target_url: "http://127.0.0.1:5000",
      skip_health_check: true
    }

    bad =
      Map.merge(first, %{
        target_id: "green",
        target_url: "http://127.0.0.1:9",
        skip_health_check: false,
        health_timeout: 50
      })

    assert {:ok, _state} = Gatehouse.Control.deploy(first)
    assert {:error, _reason} = Gatehouse.Control.deploy(bad)
    assert {:ok, "health-fail", "blue"} = Gatehouse.RouteTable.lookup("health.example.com")
  end

  test "checkin removes drained old targets" do
    first = %{
      service: "drain",
      hosts: ["drain.example.com"],
      target_id: "blue",
      target_url: "http://127.0.0.1:5000",
      skip_health_check: true
    }

    second = %{first | target_id: "green", target_url: "http://127.0.0.1:5001"}

    assert {:ok, _target} = Gatehouse.Control.deploy(first)
    assert {:ok, target} = Gatehouse.Control.checkout("drain", "blue")
    assert target.active_requests == 1
    assert {:ok, state} = Gatehouse.Control.deploy(second)
    assert Map.has_key?(state.old_targets, "blue")

    assert :ok = Gatehouse.Control.checkin("drain", "blue")

    assert eventually(fn ->
             {:ok, state} = Gatehouse.Control.get_service("drain")
             refute Map.has_key?(state.old_targets, "blue")
           end)
  end

  test "snapshot can be saved and loaded" do
    path = Path.join(System.tmp_dir!(), "gatehouse-#{System.unique_integer([:positive])}.etf")

    spec = %{
      service: "persist",
      hosts: ["persist.example.com"],
      target_id: "green",
      target_url: "http://127.0.0.1:7000",
      skip_health_check: true
    }

    assert {:ok, _state} = Gatehouse.Control.deploy(spec)
    assert :ok = Gatehouse.Control.save(path)
    assert {:ok, %{services: services}} = Gatehouse.Store.load(path)
    assert Enum.any?(services, &(&1.id == "persist"))
    File.rm(path)
  end

  defp eventually(assertion, attempts \\ 20)

  defp eventually(assertion, attempts) when attempts > 0 do
    assertion.()
    true
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end
end
