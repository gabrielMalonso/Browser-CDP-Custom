#!/usr/bin/env bash

# Shared helpers for using the Mac as an Apple-only executor.

APPLE_REMOTE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLE_REMOTE_REPO_ROOT="${REPO_ROOT:-}"
if [[ -z "$APPLE_REMOTE_REPO_ROOT" ]]; then
  APPLE_REMOTE_REPO_ROOT="$(git -C "$APPLE_REMOTE_SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [[ -z "$APPLE_REMOTE_REPO_ROOT" ]]; then
  APPLE_REMOTE_REPO_ROOT="$(cd "$APPLE_REMOTE_SCRIPT_DIR/.." && pwd)"
fi

APPLE_REMOTE_ENV_FILE="${APPLE_REMOTE_ENV_FILE:-$APPLE_REMOTE_REPO_ROOT/.apple-remote.env}"
if [[ -f "$APPLE_REMOTE_ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$APPLE_REMOTE_ENV_FILE"
fi

APPLE_REMOTE_HOST="${APPLE_REMOTE_HOST:-mac-mini}"
APPLE_REMOTE_PATH="${APPLE_REMOTE_PATH:-/Volumes/SSD1TB/Projetos/Browser-CDP-Custom-linux-mirror}"
APPLE_REMOTE_DERIVED_DATA="${APPLE_REMOTE_DERIVED_DATA:-/Volumes/SSD1TB/Xcode/DerivedData/Browser-CDP-Custom-linux-mirror}"
APPLE_REMOTE_PATH_PREFIX="${APPLE_REMOTE_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin}"
APPLE_REMOTE_CONNECT_TIMEOUT="${APPLE_REMOTE_CONNECT_TIMEOUT:-10}"
APPLE_REMOTE_RSYNC_DELETE="${APPLE_REMOTE_RSYNC_DELETE:-1}"
APPLE_REMOTE_RSYNC_PROGRESS="${APPLE_REMOTE_RSYNC_PROGRESS:-0}"

apple_remote_single_quote() {
  printf "'"
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

apple_remote_ssh() {
  ssh -o ConnectTimeout="$APPLE_REMOTE_CONNECT_TIMEOUT" "$APPLE_REMOTE_HOST" "$@"
}

apple_remote_ssh_tty() {
  ssh -t -o ConnectTimeout="$APPLE_REMOTE_CONNECT_TIMEOUT" "$APPLE_REMOTE_HOST" "$@"
}

apple_remote_run_raw() {
  local command="$1"
  local bootstrap

  bootstrap="set -euo pipefail; export PATH=\"$APPLE_REMOTE_PATH_PREFIX:\$PATH\"; $command"
  apple_remote_ssh "/bin/bash -c $(apple_remote_single_quote "$bootstrap")"
}

apple_remote_run() {
  local command="$1"
  local bootstrap

  bootstrap="set -euo pipefail; export PATH=\"$APPLE_REMOTE_PATH_PREFIX:\$PATH\"; cd \"$APPLE_REMOTE_PATH\"; $command"
  apple_remote_ssh "/bin/bash -c $(apple_remote_single_quote "$bootstrap")"
}

apple_remote_run_tty() {
  local command="$1"
  local bootstrap

  bootstrap="set -euo pipefail; export PATH=\"$APPLE_REMOTE_PATH_PREFIX:\$PATH\"; cd \"$APPLE_REMOTE_PATH\"; $command"
  apple_remote_ssh_tty "/bin/bash -c $(apple_remote_single_quote "$bootstrap")"
}

apple_remote_ensure_remote_dir() {
  apple_remote_run_raw "mkdir -p $(apple_remote_single_quote "$APPLE_REMOTE_PATH") $(apple_remote_single_quote "$APPLE_REMOTE_DERIVED_DATA")"
}

apple_remote_rsync_destination() {
  local escaped_path
  printf -v escaped_path "%q" "$APPLE_REMOTE_PATH"
  printf "%s:%s/" "$APPLE_REMOTE_HOST" "$escaped_path"
}

apple_remote_print_config() {
  echo "APPLE_REMOTE_HOST=$APPLE_REMOTE_HOST"
  echo "APPLE_REMOTE_PATH=$APPLE_REMOTE_PATH"
  echo "APPLE_REMOTE_DERIVED_DATA=$APPLE_REMOTE_DERIVED_DATA"
  echo "APPLE_REMOTE_PATH_PREFIX=$APPLE_REMOTE_PATH_PREFIX"
}
