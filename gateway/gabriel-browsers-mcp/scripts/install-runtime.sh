#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd -- "${script_dir}/.." && pwd)"
if [[ -n "${GABRIEL_BROWSERS_INSTALL_ROOT:-}" ]]; then
  install_root="${GABRIEL_BROWSERS_INSTALL_ROOT}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  install_root="${HOME}/.codex/gabriel-browsers-mcp"
else
  install_root="${HOME}/.local/share/gabriel-browsers-mcp"
fi
version="$(node -p "require('${source_root}/package.json').version")"
release_id="${GABRIEL_BROWSERS_RELEASE_ID:-${version}-$(date -u +%Y%m%dT%H%M%SZ)}"
release_dir="${install_root}/releases/${release_id}"
current_link="${install_root}/current"
bin_dir="${GABRIEL_BROWSERS_BIN_DIR:-${HOME}/.local/bin}"
browserctl_link="${bin_dir}/gabriel-browserctl"

if [[ -e "${release_dir}" || -L "${release_dir}" ]]; then
  echo "Release já existe: ${release_dir}" >&2
  exit 73
fi
if [[ -e "${current_link}" && ! -L "${current_link}" ]]; then
  echo "O caminho current existe e não é symlink: ${current_link}" >&2
  exit 73
fi
if [[ -e "${browserctl_link}" && ! -L "${browserctl_link}" ]]; then
  echo "Não substituí arquivo regular: ${browserctl_link}" >&2
  exit 73
fi

mkdir -p "${install_root}/releases" "${bin_dir}"
stage="$(mktemp -d "${install_root}/.stage.XXXXXX")"
trap 'if [[ -n "${stage:-}" && -d "${stage}" ]]; then mv "${stage}" "${install_root}/failed-$(date -u +%Y%m%dT%H%M%SZ)"; fi' EXIT

cp "${source_root}/package.json" "${source_root}/package-lock.json" "${source_root}/tsconfig.json" "${source_root}/README.md" "${stage}/"
cp -R \
  "${source_root}/src" \
  "${source_root}/test" \
  "${source_root}/scripts" \
  "${source_root}/patches" \
  "${source_root}/systemd" \
  "${stage}/"

cd "${stage}"
npm ci
npm test -- --run
npm run typecheck
npm run build

mv "${stage}" "${release_dir}"
stage=""
next_link="${install_root}/.current.$$.next"
ln -s "${release_dir}" "${next_link}"
if [[ "$(uname -s)" == "Darwin" ]]; then
  mv -fh "${next_link}" "${current_link}"
else
  mv -Tf "${next_link}" "${current_link}"
fi

ln -sfn "${current_link}/scripts/gabriel-browserctl" "${browserctl_link}"

printf 'release=%s\ncurrent=%s\nbrowserctl=%s\n' "${release_dir}" "$(readlink "${current_link}")" "${browserctl_link}"
