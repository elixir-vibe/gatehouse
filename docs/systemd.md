# Running gatehouse with systemd

`Gatehouse.Systemd.unit/1` renders the service unit through the local `systemd`
package's `Systemd.UnitFile` builder and validator. The dependency is currently
wired by local path until it is published to Hex.

```elixir
Gatehouse.Systemd.unit(
  release_path: "/opt/gatehouse",
  config_path: "/etc/gatehouse/gatehouse.exs",
  env_path: "/etc/gatehouse/env",
  vm_args_path: "/etc/gatehouse/vm.args"
)
```

Example unit:

```ini
[Unit]
Description=Xamal Proxy
After=network-online.target
Wants=network-online.target
[Service]
User=gatehouse
Group=gatehouse
EnvironmentFile=-/etc/gatehouse/env
Environment=GATEHOUSE_CONFIG=/etc/gatehouse/gatehouse.exs
Environment=GATEHOUSE_STATE=/var/lib/gatehouse/state.etf
Environment=RELEASE_VM_ARGS=/etc/gatehouse/vm.args
ExecStart=/opt/gatehouse/bin/gatehouse start
ExecStop=/opt/gatehouse/bin/gatehouse stop
Restart=always
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
```

Use a pinned distribution port in `vm.args`:

```text
-name gatehouse@127.0.0.1
-setcookie ${GATEHOUSE_COOKIE}
-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
```

Keep EPMD and distribution ports private or reachable only through SSH tunnels.
