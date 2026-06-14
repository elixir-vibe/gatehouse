defmodule Gatehouse.TelemetryTest do
  use ExUnit.Case, async: false

  test "deploy emits telemetry" do
    test_pid = self()
    ref = make_ref()

    :telemetry.detach("gatehouse-deploy-test")

    :telemetry.attach(
      "gatehouse-deploy-test",
      [:gatehouse, :deploy, :stop],
      &__MODULE__.handle_event/4,
      {test_pid, ref}
    )

    assert {:ok, _state} =
             Gatehouse.Control.deploy(%{
               service: "telemetry",
               hosts: ["telemetry.example.com"],
               target_id: "blue",
               target_url: "http://127.0.0.1:4000",
               skip_health_check: true
             })

    assert_receive {^ref, [:gatehouse, :deploy, :stop], %{duration: duration}, metadata}
    assert is_integer(duration)
    assert metadata.service == "telemetry"
    assert metadata.result == :ok
  after
    :telemetry.detach("gatehouse-deploy-test")
  end

  def handle_event(event, measurements, metadata, {test_pid, ref}) do
    send(test_pid, {ref, event, measurements, metadata})
  end
end
