#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/apple-remote-lib.sh
source "$SCRIPT_DIR/apple-remote-lib.sh"

echo "==> Apple remote doctor"
apple_remote_print_config

remote_path_q="$(apple_remote_single_quote "$APPLE_REMOTE_PATH")"
derived_data_q="$(apple_remote_single_quote "$APPLE_REMOTE_DERIVED_DATA")"

apple_remote_run_raw "
echo \"host=\$(hostname)\"
echo \"macos=\$(sw_vers -productVersion 2>/dev/null || true)\"
echo \"arch=\$(uname -m)\"

if command -v xcodebuild >/dev/null 2>&1; then
  printf 'xcode='
  xcodebuild -version | tr '\n' ' '
  printf '\n'
else
  echo 'missing=xcodebuild'
fi

echo \"developer_dir=\$(xcode-select -p 2>/dev/null || true)\"
echo \"path=\$PATH\"

for tool in rsync xcrun swift xcodebuild; do
  if command -v \"\$tool\" >/dev/null 2>&1; then
    printf 'tool.%s=%s\n' \"\$tool\" \"\$(command -v \"\$tool\")\"
  else
    printf 'missing=%s\n' \"\$tool\"
  fi
done

mkdir -p $remote_path_q $derived_data_q
[[ -w $remote_path_q ]] && echo 'mirror=writable' || echo 'mirror=not-writable'
[[ -w $derived_data_q ]] && echo 'derived_data=writable' || echo 'derived_data=not-writable'
df -h / /Volumes/SSD1TB 2>/dev/null || true
"
