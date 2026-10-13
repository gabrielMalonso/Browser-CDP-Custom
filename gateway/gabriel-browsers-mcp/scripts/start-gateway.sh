#!/usr/bin/env bash
set -euo pipefail

script_path="${BASH_SOURCE[0]}"
while [[ -L "${script_path}" ]]; do
  link_dir="$(cd -P -- "$(dirname -- "${script_path}")" && pwd)"
  link_target="$(readlink "${script_path}")"
  if [[ "${link_target}" == /* ]]; then
    script_path="${link_target}"
  else
    script_path="${link_dir}/${link_target}"
  fi
done
script_dir="$(cd -P -- "$(dirname -- "${script_path}")" && pwd)"
runtime_root="${GABRIEL_BROWSERS_MCP_ROOT:-$(cd -- "${script_dir}/.." && pwd)}"
env_file="${GABRIEL_BROWSERS_ENV_FILE:-${HOME}/.codex/gabriel-browsers-mcp.env}"

if [[ -f "${env_file}" ]]; then
  set -a
  . "${env_file}"
  set +a
fi

if [[ -z "${GABRIEL_BROWSERS_MCP_TOKEN:-}" ]]; then
  echo "GABRIEL_BROWSERS_MCP_TOKEN ausente em ${env_file}" >&2
  exit 78
fi

node_bin="${GABRIEL_BROWSERS_NODE:-$(command -v node || true)}"
if [[ -z "${node_bin}" || ! -x "${node_bin}" ]]; then
  echo "Node.js não encontrado. Defina GABRIEL_BROWSERS_NODE." >&2
  exit 69
fi

cd "${runtime_root}"
exec "${node_bin}" "${runtime_root}/dist/src/index.js"
