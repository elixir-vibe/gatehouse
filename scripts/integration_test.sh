#!/usr/bin/env sh
set -eu

VM_NAME="${GATEHOUSE_LIMA_VM:-gatehouse-test}"
WORKSPACE_DIR="${GATEHOUSE_WORKSPACE_DIR:-$(cd .. && pwd)}"
REMOTE_BASE="${GATEHOUSE_REMOTE_BASE:-~/gatehouse-integration}"
REMOTE_DIR="$REMOTE_BASE/gatehouse"
LIMACTL="${LIMACTL:-limactl}"

if ! command -v "$LIMACTL" >/dev/null 2>&1; then
  if [ -x "$HOME/.local/bin/limactl" ]; then
    LIMACTL="$HOME/.local/bin/limactl"
  else
    echo "limactl not found. Install Lima or set LIMACTL=/path/to/limactl." >&2
    exit 127
  fi
fi

copy_repo() {
  repo="$1"
  "$LIMACTL" shell "$VM_NAME" -- sh -lc "rm -rf $REMOTE_BASE/$repo && mkdir -p $REMOTE_BASE/$repo"
  tar -C "$WORKSPACE_DIR/$repo" --exclude=_build --exclude=deps --exclude=doc -cf - . |
    "$LIMACTL" shell "$VM_NAME" -- tar -C "$REMOTE_BASE/$repo" -xf -
}

copy_repo safe_rpc
copy_repo systemdkit
copy_repo gatehouse

"$LIMACTL" shell "$VM_NAME" -- sh -lc "
  cd $REMOTE_DIR &&
  mix deps.get >/dev/null &&
  GATEHOUSE_INTEGRATION=1 mix test
"
