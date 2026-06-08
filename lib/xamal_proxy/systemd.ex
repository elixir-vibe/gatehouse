defmodule XamalProxy.Systemd do
  @moduledoc """
  Generate systemd unit content for xamal_proxy deployments.
  """

  @spec unit(keyword()) :: String.t()
  def unit(opts) do
    user = Keyword.get(opts, :user, "xamal-proxy")
    group = Keyword.get(opts, :group, user)
    release_path = Keyword.get(opts, :release_path, "/opt/xamal-proxy")
    config_path = Keyword.get(opts, :config_path, "/etc/xamal-proxy.exs")
    state_path = Keyword.get(opts, :state_path, "/var/lib/xamal-proxy/state.etf")

    """
    [Unit]
    Description=Xamal Proxy
    After=network-online.target
    Wants=network-online.target

    [Service]
    User=#{user}
    Group=#{group}
    Environment=XAMAL_PROXY_CONFIG=#{config_path}
    Environment=XAMAL_PROXY_STATE=#{state_path}
    ExecStart=#{release_path}/bin/xamal_proxy start
    ExecStop=#{release_path}/bin/xamal_proxy stop
    Restart=always
    RestartSec=5
    LimitNOFILE=1048576

    [Install]
    WantedBy=multi-user.target
    """
  end
end
