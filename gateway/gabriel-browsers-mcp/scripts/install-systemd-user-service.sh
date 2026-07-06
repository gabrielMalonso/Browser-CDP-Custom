#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
gateway_dir="$(cd -- "${script_dir}/.." && pwd)"
service_source="${gateway_dir}/systemd/gabriel-browsers-mcp.service"
service_dir="${HOME}/.config/systemd/user"
service_target="${service_dir}/gabriel-browsers-mcp.service"
env_file="${HOME}/.codex/gabriel-browsers-mcp.env"

mkdir -p "${service_dir}" "${HOME}/.codex"

if [[ ! -f "${env_file}" ]]; then
  token="$(node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))")"
  printf 'GABRIEL_BROWSERS_MCP_TOKEN=%s\n' "${token}" > "${env_file}"
  chmod 0600 "${env_file}"
  echo "Token criado em ${env_file}"
fi

cp "${service_source}" "${service_target}"
systemctl --user daemon-reload
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE || true

if command -v dbus-update-activation-environment >/dev/null 2>&1; then
  dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE || true
fi

systemctl --user enable --now gabriel-browsers-mcp.service
systemctl --user --no-pager status gabriel-browsers-mcp.service
