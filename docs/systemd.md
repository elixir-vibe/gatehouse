# Running xamal_proxy with systemd

`XamalProxy.Systemd.unit/1` renders the service unit through the local `systemd`
package's `Systemd.UnitFile` builder and validator. The dependency is currently
wired by local path until it is published to Hex.

```elixir
XamalProxy.Systemd.unit(
  release_path: "/opt/xamal-proxy",
  config_path: "/etc/xamal-proxy/xamal_proxy.exs",
  env_path: "/etc/xamal-proxy/env",
  vm_args_path: "/etc/xamal-proxy/vm.args"
)
```

Example unit:

```ini
[Unit]
Description=Xamal Proxy
After=network-online.target
Wants=network-online.target
[Service]
User=xamal-proxy
Group=xamal-proxy
EnvironmentFile=-/etc/xamal-proxy/env
Environment=XAMAL_PROXY_CONFIG=/etc/xamal-proxy/xamal_proxy.exs
Environment=XAMAL_PROXY_STATE=/var/lib/xamal-proxy/state.etf
Environment=RELEASE_VM_ARGS=/etc/xamal-proxy/vm.args
ExecStart=/opt/xamal-proxy/bin/xamal_proxy start
ExecStop=/opt/xamal-proxy/bin/xamal_proxy stop
Restart=always
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
```

Use a pinned distribution port in `vm.args`:

```text
-name xamal_proxy@127.0.0.1
-setcookie ${XAMAL_PROXY_COOKIE}
-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
```

Keep EPMD and distribution ports private or reachable only through SSH tunnels.
