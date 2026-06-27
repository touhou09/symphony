#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${SYMPHONY_WORKSPACE_ROOT:-/var/lib/symphony/workspaces}" /var/log/symphony /root/.codex

exec "$@"
