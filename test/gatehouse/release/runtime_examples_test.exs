defmodule Gatehouse.Release.RuntimeExamplesTest do
  use ExUnit.Case, async: true

  test "runtime and vm args examples exist" do
    assert File.exists?("rel/runtime.exs.example")
    assert File.exists?("rel/vm.args.example")

    assert File.read!("rel/runtime.exs.example") =~ "GATEHOUSE_CONFIG"
    assert File.read!("rel/vm.args.example") =~ "inet_dist_listen_min"
  end
end
