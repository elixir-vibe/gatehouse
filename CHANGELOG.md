# Changelog

## v0.1.0

Initial package release.

### Added

- Added OTP-native edge proxy and blue-green traffic switcher primitives.
- Added runtime config DSL for HTTP/HTTPS listeners, services, targets, health checks, draining, and TLS settings.
- Added Livery-based HTTP ingress and Gun-backed backend request forwarding.
- Added WebSocket proxying for upgraded connections.
- Added ACME provider boundary, ExAcme provider integration, certificate persistence, SNI lookup, and renewal scheduling.
- Added distribution-friendly `Gatehouse.Control` deployment API.
- Added systemd helper APIs and release runtime examples.
- Added Phoenix-friendly development proxy tasks and documentation: `mix gatehouse.phx`, `mix gatehouse.run`, `mix gatehouse.trust`, and `mix gatehouse.routes`.
- Added local development CA and `.localhost` host certificate generation for HTTPS dev proxying.
- Added local HTTPS HTTP/1.1 proxy support for Phoenix apps, including LiveView/WebSocket traffic.
- Added `--open`, `--no-tls`, `--host`, `--proxy-port`, `--backend-port`, and `--cert-dir` options for development proxy tasks.

### Changed

- Livery request host lookup now prefers HTTP/2 authority before falling back to the `host` header.
- Gatehouse listener options now preserve Livery `:transport`, enabling HTTP listeners over SSL for local HTTPS dev use.
- WebSocket proxying now strips browser `sec-websocket-*` handshake headers before backend upgrades so Gun can generate a valid backend handshake.

### Fixed

- Fixed missing-route handling in the Livery proxy handler by mapping route lookup misses to `404` responses.
- Fixed bodyless `GET`/`HEAD` forwarding when Livery represents the body as a stream without content framing headers.
- Fixed backend connection pool crashes when Gun reports a pooled connection as down.
