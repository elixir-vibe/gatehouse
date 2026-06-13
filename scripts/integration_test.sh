#!/usr/bin/env sh
set -eu

VM_NAME="${XAMAL_PROXY_LIMA_VM:-xamal-proxy-test}"
PROJECT_DIR="${XAMAL_PROXY_PROJECT_DIR:-$(pwd)}"
REMOTE_DIR="${XAMAL_PROXY_REMOTE_DIR:-~/xamal-proxy-test-src}"

~/.local/bin/limactl shell "$VM_NAME" -- sh -lc "
  rm -rf $REMOTE_DIR &&
  mkdir -p $REMOTE_DIR &&
  tar -C '$PROJECT_DIR' --exclude=_build --exclude=deps --exclude=doc -cf - . | tar -C $REMOTE_DIR -xf - &&
  cd $REMOTE_DIR &&
  mix deps.get >/dev/null &&
  XAMAL_PROXY_INTEGRATION=1 mix test
"
