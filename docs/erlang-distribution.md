# Secure Erlang distribution setup

`xamal_proxy` is controlled with Erlang distribution so Xamal can call:

```elixir
:rpc.call(:"xamal_proxy@host", XamalProxy.Control, :deploy, [spec], 60_000)
```

Keep distribution private:

1. Bind the proxy node to a private address or localhost.
2. Pin the distribution port range with VM args:

   ```text
   -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
   ```

3. Do not expose EPMD or distribution ports on the public Internet.
4. Use a unique high-entropy cookie per environment.
5. Prefer SSH tunneling for deploys from a workstation or CI runner.
6. Use host firewall rules to allow distribution only from trusted deploy hosts.

Example SSH tunnel:

```sh
ssh -L 4369:127.0.0.1:4369 -L 9100:127.0.0.1:9100 deploy@example.com
```

Example local deploy node:

```sh
elixir \
  --sname xamal_deployer \
  --cookie "$XAMAL_PROXY_COOKIE" \
  --eval 'IO.inspect(:rpc.call(:"xamal_proxy@127.0.0.1", XamalProxy.Control, :routes, [], 5000))'
```

For public or multi-host distribution, add TLS distribution before exposing any
ports beyond the private network.
