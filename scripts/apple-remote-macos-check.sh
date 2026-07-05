#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/apple-remote-lib.sh
source "$SCRIPT_DIR/apple-remote-lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/apple-remote-macos-check.sh [options]

Sync to the Mac mirror, then run this repo's macOS Swift checks.

Options:
      --no-sync            Reuse the current remote mirror without rsync
      --skip-package-app   Do not run scripts/build-app.sh after tests
  -h, --help               Show this help
EOF
}

RUN_SYNC=1
PACKAGE_APP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-sync)
      RUN_SYNC=0
      ;;
    --skip-package-app)
      PACKAGE_APP=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$RUN_SYNC" == "1" ]]; then
  "$SCRIPT_DIR/apple-remote-sync.sh"
fi

package_command=""
if [[ "$PACKAGE_APP" == "1" ]]; then
  package_command="
echo '==> macOS package app'
scripts/build-app.sh
test -x .build/app/Custom-CDP-Browser.app/Contents/MacOS/CustomCDPBrowser
/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' .build/app/Custom-CDP-Browser.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:1' .build/app/Custom-CDP-Browser.app/Contents/Info.plist
"
fi

apple_remote_run "
echo '==> macOS swift build'
swift build

echo '==> macOS swift test'
swift test

$package_command
"

echo "==> macOS remote checks passed"
