# Running xamal_proxy with systemd

Example unit:

```ini
[Unit]
Description=Xamal Proxy
After=network-online.target
Wants=network-online.target

[Service]
User=xamal-proxy
Group=xamal-proxy
Environment=XAMAL_PROXY_CONFIG=/etc/xamal-proxy.exs
Environment=XAMAL_PROXY_STATE=/var/lib/xamal-proxy/state.etf
Environment=XAMAL_PROXY_COOKIE=replace-with-secret
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
