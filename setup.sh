#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOTUNE_SCRIPT="${SCRIPT_DIR}/autotune-deploy.sh"

# 解析命令行参数
for arg in "$@"; do
    case "$arg" in
        --portal-url=*)  export PORTAL_URL="${arg#*=}" ;;
        --token=*)       export REGISTER_TOKEN="${arg#*=}" ;;
        --public-ip=*)   export PUBLIC_IP="${arg#*=}" ;;
    esac
done

if [ ! -x "${AUTOTUNE_SCRIPT}" ]; then
    chmod +x "${AUTOTUNE_SCRIPT}" 2>/dev/null || true
fi

if [ ! -f "${AUTOTUNE_SCRIPT}" ]; then
    echo "autotune-deploy.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

echo "[setup.sh] Delegating to autotune-deploy.sh ..."
exec "${AUTOTUNE_SCRIPT}" "$@"
