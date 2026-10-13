#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${GABRIEL_BROWSERS_INSTALL_ROOT:-}" ]]; then
  install_root="${GABRIEL_BROWSERS_INSTALL_ROOT}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  install_root="${HOME}/.codex/gabriel-browsers-mcp"
else
  install_root="${HOME}/.local/share/gabriel-browsers-mcp"
fi
release_name="${1:-}"
release_dir="${install_root}/releases/${release_name}"
current_link="${install_root}/current"

if [[ -z "${release_name}" || ! -d "${release_dir}" ]]; then
  echo "Informe uma release existente em ${install_root}/releases." >&2
  exit 64
fi
if [[ -e "${current_link}" && ! -L "${current_link}" ]]; then
  echo "O caminho current existe e não é symlink: ${current_link}" >&2
  exit 73
fi

next_link="${install_root}/.current.$$.next"
ln -s "${release_dir}" "${next_link}"
if [[ "$(uname -s)" == "Darwin" ]]; then
  mv -fh "${next_link}" "${current_link}"
else
  mv -Tf "${next_link}" "${current_link}"
fi
printf 'current=%s\n' "$(readlink "${current_link}")"
