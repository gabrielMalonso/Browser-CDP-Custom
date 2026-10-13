#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
gateway_dir="$(cd -- "${script_dir}/.." && pwd)"
service_source="${gateway_dir}/systemd/gabriel-browsers-mcp.service"
service_dir="${HOME}/.config/systemd/user"
service_target="${service_dir}/gabriel-browsers-mcp.service"
env_file="${HOME}/.codex/gabriel-browsers-mcp.env"
runtime="${GABRIEL_BROWSERS_INSTALL_ROOT:-${HOME}/.local/share/gabriel-browsers-mcp}/current"
restart=true

if [[ "${1:-}" == "--no-restart" ]]; then
  restart=false
fi

if [[ ! -x "${runtime}/scripts/start-gateway.sh" ]]; then
  echo "Runtime não instalado em ${runtime}. Rode scripts/install-runtime.sh primeiro." >&2
  exit 69
fi

mkdir -p "${service_dir}" "${HOME}/.codex"

if [[ ! -f "${env_file}" ]]; then
  token="$(node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))")"
  printf 'GABRIEL_BROWSERS_MCP_TOKEN=%s\n' "${token}" > "${env_file}"
  chmod 0600 "${env_file}"
  echo "Token criado em ${env_file}"
fi
chmod 0600 "${env_file}"

if [[ -f "${service_target}" ]]; then
  cp "${service_target}" "${service_target}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
fi
cp "${service_source}" "${service_target}"
systemctl --user daemon-reload
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE || true

if command -v dbus-update-activation-environment >/dev/null 2>&1; then
  dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE || true
fi

systemctl --user enable gabriel-browsers-mcp.service
if [[ "${restart}" == true ]]; then
  systemctl --user restart gabriel-browsers-mcp.service
  healthy=false
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 1 http://127.0.0.1:8787/health >/dev/null; then
      healthy=true
      break
    fi
    sleep 1
  done
  if [[ "${healthy}" != true ]]; then
    echo "gabriel-browsers-mcp.service iniciou, mas /health não respondeu." >&2
    exit 70
  fi
fi
systemctl --user --no-pager status gabriel-browsers-mcp.service
