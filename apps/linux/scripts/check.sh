#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "${script_dir}/.." && pwd)"

cd "${app_dir}"

cargo fmt --all -- --check
cargo test -p browser-cdp-core
npm run check
npm run build

if pkg-config --exists dbus-1 webkit2gtk-4.1 gtk+-3.0 libsoup-3.0; then
  cargo check -p browser-cdp-custom-linux
else
  if [[ "${REQUIRE_TAURI:-}" == "1" ]]; then
    cat >&2 <<'EOF'
Erro: faltam dependências nativas para compilar a app Tauri.
Ubuntu:
  sudo apt install pkg-config libdbus-1-dev libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev
EOF
    exit 1
  fi

  cat >&2 <<'EOF'
Aviso: check Tauri pulado porque faltam dependências nativas de desenvolvimento.
Ubuntu:
  sudo apt install pkg-config libdbus-1-dev libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev
EOF
fi
