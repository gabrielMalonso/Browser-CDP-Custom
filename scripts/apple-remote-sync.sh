#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/apple-remote-lib.sh
source "$SCRIPT_DIR/apple-remote-lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/apple-remote-sync.sh [options]

Sync this Ubuntu checkout to the disposable Mac mirror.

Options:
  -n, --dry-run   Show what would be synced without copying files
      --no-delete Do not delete remote files that disappeared locally
      --delete    Delete remote files that disappeared locally (default)
      --progress  Show rsync progress
  -v, --verbose   Show transferred file names
  -h, --help      Show this help
EOF
}

DRY_RUN=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      ;;
    --no-delete)
      APPLE_REMOTE_RSYNC_DELETE=0
      ;;
    --delete)
      APPLE_REMOTE_RSYNC_DELETE=1
      ;;
    --progress)
      APPLE_REMOTE_RSYNC_PROGRESS=1
      ;;
    -v|--verbose)
      VERBOSE=1
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

echo "==> Apple remote sync"
apple_remote_print_config

echo "==> Ensuring remote mirror directory"
apple_remote_ensure_remote_dir

rsync_args=(-az)

if [[ "$VERBOSE" == "1" ]]; then
  rsync_args=(-avz --human-readable)
fi

if [[ "$APPLE_REMOTE_RSYNC_DELETE" == "1" ]]; then
  rsync_args+=(--delete)
fi

if [[ "$APPLE_REMOTE_RSYNC_PROGRESS" == "1" ]]; then
  rsync_args+=(--info=progress2)
fi

if [[ "$DRY_RUN" == "1" ]]; then
  rsync_args+=(--dry-run --itemize-changes)
fi

rsync_excludes=(
  --exclude='.git/'
  --exclude='.apple-remote.env'
  --exclude='.Codex/'
  --exclude='.claude/'
  --exclude='.playwright-mcp/'
  --exclude='.t3code/'
  --exclude='**/.DS_Store'
  --exclude='**/node_modules/'
  --exclude='**/.build/'
  --exclude='**/.swiftpm/'
  --exclude='**/DerivedData/'
  --exclude='**/build/'
  --exclude='**/dist/'
  --exclude='**/target/'
  --exclude='**/*.xcworkspace/'
)

remote_destination="$(apple_remote_rsync_destination)"

echo "==> Syncing to $remote_destination"
rsync \
  "${rsync_args[@]}" \
  "${rsync_excludes[@]}" \
  -e "ssh -o ConnectTimeout=$APPLE_REMOTE_CONNECT_TIMEOUT" \
  "$APPLE_REMOTE_REPO_ROOT/" \
  "$remote_destination"

echo "==> Sync complete"
