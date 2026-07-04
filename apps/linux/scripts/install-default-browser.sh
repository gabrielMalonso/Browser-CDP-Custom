#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Uso: apps/linux/scripts/install-default-browser.sh --yes

Registra o app Linux como handler de http/https no Ubuntu.
Por segurança, sem --yes ele só mostra o que faria.

Pré-requisito:
  cd apps/linux
  npm install
  npm run tauri build
EOF
}

apply="false"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--yes" ]]; then
  apply="true"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "${script_dir}/.." && pwd)"
binary="${app_dir}/target/release/browser-cdp-custom-linux"
desktop_dir="${HOME}/.local/share/applications"
desktop_file="${desktop_dir}/browser-cdp-custom-linux.desktop"

if [[ ! -x "${binary}" ]]; then
  echo "Binário não encontrado em: ${binary}" >&2
  echo "Rode: cd ${app_dir} && npm install && npm run tauri build" >&2
  exit 1
fi

desktop_body="[Desktop Entry]
Type=Application
Name=Browser CDP Custom Linux
Comment=Roteia links http/https para perfis Chrome CDP persistentes.
Exec=${binary} %u
Terminal=false
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;
StartupNotify=true"

echo "Arquivo .desktop: ${desktop_file}"
echo "Handlers: x-scheme-handler/http e x-scheme-handler/https"

if [[ "${apply}" != "true" ]]; then
  echo
  echo "${desktop_body}"
  echo
  echo "Nada foi alterado. Rode com --yes para aplicar."
  exit 0
fi

mkdir -p "${desktop_dir}"
printf '%s\n' "${desktop_body}" > "${desktop_file}"
chmod 0644 "${desktop_file}"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "${desktop_file}"
fi

xdg-mime default browser-cdp-custom-linux.desktop x-scheme-handler/http
xdg-mime default browser-cdp-custom-linux.desktop x-scheme-handler/https
update-desktop-database "${desktop_dir}" >/dev/null 2>&1 || true

echo "http:  $(xdg-mime query default x-scheme-handler/http)"
echo "https: $(xdg-mime query default x-scheme-handler/https)"
