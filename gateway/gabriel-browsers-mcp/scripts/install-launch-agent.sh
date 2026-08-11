#!/usr/bin/env bash
set -euo pipefail

label="com.gabrielalonso.gabriel-browsers-mcp"
install_root="${GABRIEL_BROWSERS_INSTALL_ROOT:-${HOME}/.codex/gabriel-browsers-mcp}"
runtime="${install_root}/current"
env_file="${HOME}/.codex/gabriel-browsers-mcp.env"
agent_dir="${HOME}/Library/LaunchAgents"
agent_file="${agent_dir}/${label}.plist"
log_dir="${HOME}/.codex/log"
node_bin="${GABRIEL_BROWSERS_NODE:-$(command -v node || true)}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Este instalador roda apenas no macOS." >&2
  exit 69
fi
if [[ ! -x "${runtime}/scripts/start-gateway.sh" ]]; then
  echo "Runtime não instalado em ${runtime}. Rode scripts/install-runtime.sh primeiro." >&2
  exit 69
fi
if [[ -z "${node_bin}" || ! -x "${node_bin}" ]]; then
  echo "Node.js não encontrado." >&2
  exit 69
fi

mkdir -p "${agent_dir}" "${log_dir}" "${HOME}/.codex"
if [[ ! -f "${env_file}" ]]; then
  token="$("${node_bin}" -e "console.log(require('crypto').randomBytes(32).toString('base64url'))")"
  printf 'GABRIEL_BROWSERS_MCP_TOKEN=%s\n' "${token}" > "${env_file}"
fi
chmod 0600 "${env_file}"
if [[ -f "${agent_file}" ]]; then
  cp "${agent_file}" "${agent_file}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
fi

node_dir="$(dirname "${node_bin}")"
{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0"><dict>'
  printf '  <key>Label</key><string>%s</string>\n' "${label}"
  printf '  <key>ProgramArguments</key><array><string>/bin/bash</string><string>%s/scripts/start-gateway.sh</string></array>\n' "${runtime}"
  printf '  <key>WorkingDirectory</key><string>%s</string>\n' "${runtime}"
  printf '%s\n' '  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>'
  printf '  <key>StandardOutPath</key><string>%s/gabriel-browsers-mcp.out.log</string>\n' "${log_dir}"
  printf '  <key>StandardErrorPath</key><string>%s/gabriel-browsers-mcp.err.log</string>\n' "${log_dir}"
  printf '  <key>EnvironmentVariables</key><dict><key>PATH</key><string>%s:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>\n' "${node_dir}"
  printf '%s\n' '</dict></plist>'
} > "${agent_file}"

plutil -lint "${agent_file}"
launchctl bootout "gui/${UID}/${label}" >/dev/null 2>&1 || true
bootstrapped=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if launchctl print "gui/${UID}/${label}" >/dev/null 2>&1; then
    sleep 1
    continue
  fi
  if launchctl bootstrap "gui/${UID}" "${agent_file}"; then
    bootstrapped=true
    break
  fi
  sleep 1
done
if [[ "${bootstrapped}" != true ]]; then
  echo "Não foi possível carregar ${label} após 10 tentativas." >&2
  exit 70
fi
launchctl enable "gui/${UID}/${label}"
launchctl kickstart -k "gui/${UID}/${label}"
healthy=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if /usr/bin/curl -fsS --max-time 1 http://127.0.0.1:8787/health >/dev/null; then
    healthy=true
    break
  fi
  sleep 1
done
if [[ "${healthy}" != true ]]; then
  echo "${label} foi carregado, mas /health não respondeu." >&2
  exit 70
fi
launchctl print "gui/${UID}/${label}"
