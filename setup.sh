#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOTUNE_SCRIPT="${SCRIPT_DIR}/autotune-deploy.sh"

if [ ! -x "${AUTOTUNE_SCRIPT}" ]; then
    chmod +x "${AUTOTUNE_SCRIPT}" 2>/dev/null || true
fi

if [ ! -f "${AUTOTUNE_SCRIPT}" ]; then
    echo "autotune-deploy.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

echo "[setup.sh] Delegating to autotune-deploy.sh ..."
exec "${AUTOTUNE_SCRIPT}" "$@"
