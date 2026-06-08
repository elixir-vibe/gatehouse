defmodule XamalProxy.SystemdTest do
  use ExUnit.Case, async: true

  test "generates a systemd unit" do
    unit = XamalProxy.Systemd.unit(release_path: "/opt/proxy", config_path: "/etc/proxy.exs")

    assert unit =~ "Description=Xamal Proxy"
    assert unit =~ "Environment=XAMAL_PROXY_CONFIG=/etc/proxy.exs"
    assert unit =~ "ExecStart=/opt/proxy/bin/xamal_proxy start"
    assert unit =~ "Restart=always"
  end
end
