# Phoenix local HTTPS development

Gatehouse can run a Phoenix development server behind a stable local `.localhost`
URL with HTTPS. This is useful when developing features that depend on secure
origins, stable callback URLs, cookies, or LiveView/WebSocket behavior.

## Install

Add Gatehouse to your Phoenix app in development:

```elixir
def deps do
  [
    {:gatehouse, "~> 0.1", only: :dev, runtime: false}
  ]
end
```

Then fetch dependencies:

```sh
mix deps.get
```

## Trust the local CA

Gatehouse creates a development-only CA under `~/.gatehouse/dev_certs` by
default:

```sh
mix gatehouse.trust
```

The task prints OS-specific trust-store commands. It intentionally does not run
`sudo` for you.

## Run Phoenix through Gatehouse

```sh
mix gatehouse.phx
```

This starts:

- a Phoenix backend on a free `127.0.0.1` port exposed as `PORT`
- a Gatehouse HTTPS proxy on `https://<app-name>.localhost:4443`
- a local Gatehouse route from the `.localhost` host to the backend

Use `--open` to open the stable URL in your browser:

```sh
mix gatehouse.phx --open
```

## Endpoint configuration

Your Phoenix endpoint must read `PORT` in development:

```elixir
config :my_app, MyAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: ["https://my-app.localhost:4443"]
```

Regular requests, static assets, and LiveView/WebSocket traffic are proxied
through the same HTTPS origin.

## Custom commands

Use `gatehouse.run` when you need a command other than `mix phx.server`:

```sh
mix gatehouse.run -- mix phx.server
mix gatehouse.run --open -- mix phx.server
mix gatehouse.run --host admin.localhost --proxy-port 443 -- mix phx.server
mix gatehouse.run --no-tls -- mix phx.server
```

Options:

- `--host HOST` - stable local hostname, defaults to `<otp-app>.localhost`
- `--proxy-port PORT` - local proxy port, defaults to `4443`
- `--backend-port PORT` - backend port passed to the command as `PORT`
- `--cert-dir DIR` - development CA/certificate directory
- `--no-tls` - expose the proxy over plain HTTP
- `--open` - open the proxy URL in your browser

## Troubleshooting

### Browser does not trust the certificate

Run `mix gatehouse.trust` and follow the printed trust-store instructions.

### Phoenix is still serving on port 4000

Update your dev endpoint to read the `PORT` environment variable. Gatehouse
prints the backend port it selected in the startup banner.

### Port 4443 is already in use

Stop the process using the port or choose another proxy port:

```sh
mix gatehouse.phx --proxy-port 4444
```
