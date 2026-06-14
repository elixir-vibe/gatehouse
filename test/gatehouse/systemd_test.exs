defmodule Gatehouse.SystemdTest do
  use ExUnit.Case, async: true

  test "generates a systemd unit" do
    unit = Gatehouse.Systemd.unit(release_path: "/opt/proxy", config_path: "/etc/proxy.exs")

    assert unit =~ "Description=Gatehouse Edge Proxy"
    assert unit =~ "Environment=GATEHOUSE_CONFIG=/etc/proxy.exs"
    assert unit =~ "ExecStart=/opt/proxy/bin/gatehouse start"
    assert unit =~ "Restart=always"
  end
end
