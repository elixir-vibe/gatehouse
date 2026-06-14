# DemoApp

Tiny HTTP backend for `gatehouse` playgrounds and integration tests.

Run one backend:

```sh
PORT=4000 LABEL=blue mix run --no-halt
```

Run another in a second shell:

```sh
PORT=4001 LABEL=green mix run --no-halt
```

Then point `gatehouse` targets at `http://127.0.0.1:4000` and
`http://127.0.0.1:4001`.
