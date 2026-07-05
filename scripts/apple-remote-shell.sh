#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/apple-remote-lib.sh
source "$SCRIPT_DIR/apple-remote-lib.sh"

if [[ $# -eq 0 ]]; then
  apple_remote_run_tty "exec /bin/bash -l"
else
  apple_remote_run "$*"
fi
