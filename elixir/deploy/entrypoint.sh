#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${SYMPHONY_WORKSPACE_ROOT:-/var/lib/symphony/workspaces}" /var/log/symphony /root/.codex

seed_auth_path=/run/symphony/codex-host/auth.json
runtime_auth_path=/root/.codex/auth.json

if [ -f "$seed_auth_path" ]; then
  if [ ! -f "$runtime_auth_path" ] || [ "$seed_auth_path" -nt "$runtime_auth_path" ]; then
    cp "$seed_auth_path" "$runtime_auth_path"
    chmod 600 "$runtime_auth_path" || true
  fi
fi

exec "$@"
