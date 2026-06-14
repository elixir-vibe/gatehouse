#!/usr/bin/env sh
set -eu

VM_NAME="${GATEHOUSE_LIMA_VM:-systemd-test}"
PROJECT_DIR="${GATEHOUSE_PROJECT_DIR:-/Users/dannote/Development/gatehouse}"
SYSTEMDKIT_DIR="${SYSTEMDKIT_PROJECT_DIR:-/Users/dannote/Development/systemd}"
REMOTE_DIR="${GATEHOUSE_REMOTE_DIR:-~/gatehouse-test-src}"
REMOTE_SYSTEMDKIT_DIR="${SYSTEMDKIT_REMOTE_DIR:-~/systemd}"
PEBBLE_REPO="${GATEHOUSE_PEBBLE_REPO:-https://github.com/letsencrypt/pebble.git}"
PEBBLE_REF="${GATEHOUSE_PEBBLE_REF:-v2.10.0}"
ELIXIR_VERSION="${GATEHOUSE_LIMA_ELIXIR:-elixir@1.20.0-otp-27}"
LIMACTL="${LIMACTL:-$HOME/.local/bin/limactl}"
MISE_ENV='MISE_TRUSTED_CONFIG_PATHS=/Users/dannote/.config/mise/config.toml'

ensure_pebble() {
  "$LIMACTL" shell "$VM_NAME" -- sh -lc "if [ ! -d ~/pebble-src ]; then git clone --depth 1 --branch '$PEBBLE_REF' '$PEBBLE_REPO' ~/pebble-src >/dev/null; fi"

  if "$LIMACTL" shell "$VM_NAME" -- sh -lc 'test -x ~/bin/pebble'; then
    return 0
  fi

  if ! command -v go >/dev/null 2>&1; then
    echo 'Go is required on the host to cross-build Pebble for the Lima VM' >&2
    exit 1
  fi

  vm_arch="$("$LIMACTL" shell "$VM_NAME" -- uname -m | tr -d '\r')"
  case "$vm_arch" in
    aarch64|arm64) goarch=arm64 ;;
    x86_64|amd64) goarch=amd64 ;;
    *) echo "Unsupported Lima VM arch: $vm_arch" >&2; exit 1 ;;
  esac

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  git clone --depth 1 --branch "$PEBBLE_REF" "$PEBBLE_REPO" "$tmp/pebble-src" >/dev/null
  (cd "$tmp/pebble-src" && GOOS=linux GOARCH="$goarch" go build -o "$tmp/pebble" ./cmd/pebble)

  "$LIMACTL" shell "$VM_NAME" -- sh -lc 'mkdir -p ~/bin'
  tar -C "$tmp" -cf - pebble | "$LIMACTL" shell "$VM_NAME" -- sh -lc 'tar -C ~/bin -xf - && chmod +x ~/bin/pebble'
}

copy_sources() {
  "$LIMACTL" shell "$VM_NAME" -- sh -lc "rm -rf $REMOTE_DIR $REMOTE_SYSTEMDKIT_DIR && mkdir -p $REMOTE_DIR $REMOTE_SYSTEMDKIT_DIR"
  tar -C "$PROJECT_DIR" --exclude=_build --exclude=deps --exclude=doc -cf - . | "$LIMACTL" shell "$VM_NAME" -- sh -lc "tar -C $REMOTE_DIR -xf -"
  tar -C "$SYSTEMDKIT_DIR" --exclude=_build --exclude=deps --exclude=doc -cf - . | "$LIMACTL" shell "$VM_NAME" -- sh -lc "tar -C $REMOTE_SYSTEMDKIT_DIR -xf -"
}

ensure_pebble
copy_sources

"$LIMACTL" shell "$VM_NAME" -- sh -lc '
  needs_apt=0
  if ! erl -noshell -eval '\''case code:lib_dir(syntax_tools) of {error, _} -> halt(1); _ -> halt(0) end'\'' 2>/dev/null; then
    needs_apt=1
  fi
  if ! command -v cmake >/dev/null 2>&1; then
    needs_apt=1
  fi
  if [ "$needs_apt" = 1 ]; then
    sudo apt-get update >/dev/null
    sudo apt-get install -y erlang-syntax-tools cmake build-essential >/dev/null
  fi
'

"$LIMACTL" shell "$VM_NAME" -- sh -lc "
  set -eu

  (cd ~/pebble-src && PEBBLE_VA_ALWAYS_VALID=1 PEBBLE_VA_NOSLEEP=1 ~/bin/pebble -config test/config/pebble-config.json > /tmp/gatehouse-pebble.log 2>&1) &
  pebble_pid=\$!
  trap 'kill \$pebble_pid 2>/dev/null || true' EXIT INT TERM

  cd $REMOTE_DIR
  $MISE_ENV mise x $ELIXIR_VERSION -- mix deps.get >/dev/null
  $MISE_ENV GATEHOUSE_PEBBLE=1 GATEHOUSE_PEBBLE_EXTERNAL=1 mise x $ELIXIR_VERSION -- mix test test/gatehouse/acme_pebble_integration_test.exs
"
