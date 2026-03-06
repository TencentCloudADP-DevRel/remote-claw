#!/usr/bin/env bash
# ============================================================
# OpenClaw Desktop — Portal 一键安装脚本
#
# 适用场景: 用户从 Agent Portal 个人助理页面获取安装命令
# 安装后自动注册到 Portal，由 Portal 统一管理
#
# 用法:
#   curl -fsSL <RAW_URL>/install.sh | sudo bash -s -- \
#     --portal-url=https://your-portal.com --token=YOUR_TOKEN
#
# 参数:
#   --portal-url=URL   Portal 地址（必填）
#   --token=TOKEN      注册令牌（必填，从个人助理页面获取）
#   --public-ip=IP     公网 IP（可选，自动探测）
#   --gateway-port=N   Gateway 端口（默认 18789）
#   --vnc-password=PW  VNC 密码（默认 openclaw）
# ============================================================
set -euo pipefail

# ---- 颜色输出 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }

banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
   ____                    ____ _
  / __ \_ __  ___ _ __   / ___| | __ ___      __
 | |  | | '_ \/ _ \ '_ \| |   | |/ _` \ \ /\ / /
 | |__| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \____/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
        |_|         Portal Installer v0.2.0
EOF
    echo -e "${NC}"
}

# ---- 默认值 ----
IMAGE="tencentcloudadpdevrel/openclaw-desktop:latest"
CONTAINER_NAME="openclaw-desktop"
PORTAL_URL=""
REGISTER_TOKEN=""
PUBLIC_IP=""
GATEWAY_PORT="18789"
VNC_PORT="5901"
NOVNC_PORT="6080"
VNC_PASSWORD="openclaw"
INSTALL_DIR="/opt/openclaw"

# ---- 解析参数 ----
for arg in "$@"; do
    case "$arg" in
        --portal-url=*)   PORTAL_URL="${arg#*=}" ;;
        --token=*)        REGISTER_TOKEN="${arg#*=}" ;;
        --public-ip=*)    PUBLIC_IP="${arg#*=}" ;;
        --gateway-port=*) GATEWAY_PORT="${arg#*=}" ;;
        --vnc-password=*) VNC_PASSWORD="${arg#*=}" ;;
        --help|-h)
            banner
            echo "用法: bash install.sh --portal-url=URL --token=TOKEN [--public-ip=IP]"
            exit 0 ;;
    esac
done

# ---- 校验必填参数 ----
banner

if [ -z "$PORTAL_URL" ]; then
    err "--portal-url 是必填参数"
    echo "  用法: bash install.sh --portal-url=https://your-portal.com --token=YOUR_TOKEN"
    exit 1
fi
if [ -z "$REGISTER_TOKEN" ]; then
    err "--token 是必填参数（从个人助理页面获取）"
    exit 1
fi

# ---- 检测系统环境 ----
info "检测系统环境..."
has_cmd() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
ARCH="$(uname -m)"
if [ "$OS" != "Linux" ]; then
    err "目前仅支持 Linux 系统（检测到: $OS）"
    exit 1
fi

HOST_CPUS="$(nproc)"
MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1024 / 1024 ))
DISK_FREE_GB=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')

ok "系统: $OS $ARCH | CPU: ${HOST_CPUS}核 | 内存: ${MEM_TOTAL_GB}GB | 磁盘剩余: ${DISK_FREE_GB}GB"

if [ "$MEM_TOTAL_GB" -lt 2 ]; then
    err "内存不足 2GB，无法运行 OpenClaw Desktop"
    exit 1
fi
if [ "${DISK_FREE_GB:-0}" -lt 10 ]; then
    warn "磁盘空间不足 10GB，可能影响运行"
fi

# ---- 确保 root 权限 ----
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 或 sudo 运行此脚本"
    exit 1
fi

# ---- 安装 Docker ----
ensure_docker() {
    if has_cmd docker && docker info >/dev/null 2>&1; then
        ok "Docker 已安装: $(docker --version | head -1)"
        return
    fi
    info "安装 Docker..."
    if has_cmd apt-get; then
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-plugin 2>/dev/null || curl -fsSL https://get.docker.com | sh
    elif has_cmd dnf; then
        dnf install -y -q docker docker-compose-plugin 2>/dev/null || curl -fsSL https://get.docker.com | sh
    elif has_cmd yum; then
        yum install -y -q docker docker-compose-plugin 2>/dev/null || curl -fsSL https://get.docker.com | sh
    else
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker 2>/dev/null || true
    ok "Docker 安装完成"
}
ensure_docker

if ! docker compose version >/dev/null 2>&1; then
    info "安装 Docker Compose 插件..."
    if has_cmd apt-get; then apt-get install -y -qq docker-compose-plugin
    elif has_cmd dnf; then dnf install -y -q docker-compose-plugin
    elif has_cmd yum; then yum install -y -q docker-compose-plugin
    fi
fi
ok "Docker Compose: $(docker compose version 2>/dev/null | head -1)"

# ---- 自动调优 ----
info "根据设备配置自动调优..."
clamp() { local v="$1" lo="$2" hi="$3"; [ "$v" -lt "$lo" ] && echo "$lo" && return; [ "$v" -gt "$hi" ] && echo "$hi" && return; echo "$v"; }

TUNED_CPUS=$(clamp $(( HOST_CPUS - 1 )) 2 12)
TUNED_MEM_GB=$(clamp $(( MEM_TOTAL_GB * 60 / 100 )) 2 24)
TUNED_SHM_GB=$(clamp $(( TUNED_MEM_GB / 4 )) 1 8)
FF_PROC=$(clamp $(( TUNED_CPUS / 2 )) 2 8)
FF_WEBISO=$(clamp $(( FF_PROC / 2 )) 1 4)
FF_CACHE_KB=$(clamp $(( TUNED_MEM_GB * 1024 * 1024 / 16 )) 65536 524288)

if [ "$TUNED_CPUS" -ge 8 ] && [ "$TUNED_MEM_GB" -ge 16 ]; then
    VNC_RES="1920x1080"; PROFILE="large"
elif [ "$TUNED_CPUS" -ge 4 ] && [ "$TUNED_MEM_GB" -ge 8 ]; then
    VNC_RES="1600x900"; PROFILE="medium"
else
    VNC_RES="1366x768"; PROFILE="small"
fi
ok "配置方案: ${PROFILE} | CPU: ${TUNED_CPUS} | 内存: ${TUNED_MEM_GB}GB | 分辨率: ${VNC_RES}"

# ---- 探测公网 IP ----
if [ -z "$PUBLIC_IP" ]; then
    info "探测公网 IP..."
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -fsSL --max-time 5 https://ipinfo.io/ip 2>/dev/null \
        || echo "")
    [ -n "$PUBLIC_IP" ] && ok "公网 IP: $PUBLIC_IP" || warn "无法探测公网 IP，注册可能失败"
fi

# ---- 生成配置文件 ----
info "创建安装目录: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/shared" "${INSTALL_DIR}/screenshots"

cat > "${INSTALL_DIR}/.env" <<EOF
# Auto-generated by OpenClaw Portal Installer
OPENCLAW_PROFILE=${PROFILE}
OPENCLAW_CONTAINER_NAME=${CONTAINER_NAME}
OPENCLAW_VNC_PORT=${VNC_PORT}
OPENCLAW_NOVNC_PORT=${NOVNC_PORT}
OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}
OPENCLAW_VNC_PASSWORD=${VNC_PASSWORD}
OPENCLAW_VNC_RESOLUTION=${VNC_RES}
OPENCLAW_VNC_DEPTH=24
OPENCLAW_CPUS=${TUNED_CPUS}
OPENCLAW_MEM_LIMIT=${TUNED_MEM_GB}g
OPENCLAW_SHM_SIZE=${TUNED_SHM_GB}g
OPENCLAW_FIREFOX_PROCESS_COUNT=${FF_PROC}
OPENCLAW_FIREFOX_WEB_ISOLATED_COUNT=${FF_WEBISO}
OPENCLAW_FIREFOX_CACHE_MEMORY_KB=${FF_CACHE_KB}
PORTAL_URL=${PORTAL_URL}
REGISTER_TOKEN=${REGISTER_TOKEN}
PUBLIC_IP=${PUBLIC_IP}
EOF

cat > "${INSTALL_DIR}/docker-compose.yml" <<'DEOF'
services:
  desktop:
    image: tencentcloudadpdevrel/openclaw-desktop:latest
    container_name: ${OPENCLAW_CONTAINER_NAME:-openclaw-desktop}
    hostname: openclaw
    init: true
    restart: unless-stopped
    ports:
      - "${OPENCLAW_VNC_PORT:-5901}:5901"
      - "${OPENCLAW_NOVNC_PORT:-6080}:6080"
      - "${OPENCLAW_GATEWAY_PORT:-18789}:${OPENCLAW_GATEWAY_PORT:-18789}"
    environment:
      - VNC_PW=${OPENCLAW_VNC_PASSWORD:-openclaw}
      - VNC_RESOLUTION=${OPENCLAW_VNC_RESOLUTION:-1920x1080}
      - VNC_COL_DEPTH=${OPENCLAW_VNC_DEPTH:-24}
      - GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT:-18789}
      - FIREFOX_PROCESS_COUNT=${OPENCLAW_FIREFOX_PROCESS_COUNT:-4}
      - FIREFOX_WEB_ISOLATED_COUNT=${OPENCLAW_FIREFOX_WEB_ISOLATED_COUNT:-2}
      - FIREFOX_CACHE_MEMORY_KB=${OPENCLAW_FIREFOX_CACHE_MEMORY_KB:-131072}
      - PORTAL_URL=${PORTAL_URL:-}
      - REGISTER_TOKEN=${REGISTER_TOKEN:-}
      - PUBLIC_IP=${PUBLIC_IP:-}
    security_opt:
      - seccomp=unconfined
    cap_add:
      - SYS_ADMIN
    volumes:
      - desktop-home:/root
      - ./shared:/shared
      - screenshots:/screenshots
    shm_size: "${OPENCLAW_SHM_SIZE:-2g}"
    mem_limit: "${OPENCLAW_MEM_LIMIT:-8g}"
    cpus: ${OPENCLAW_CPUS:-4}

volumes:
  desktop-home:
    driver: local
  screenshots:
    driver: local
DEOF

ok "配置文件已生成"

# ---- 拉取镜像 ----
info "拉取 OpenClaw Desktop 镜像（约 2-3GB，请耐心等待）..."
docker pull "${IMAGE}" 2>&1 | tail -5
ok "镜像拉取完成"

# ---- 停止旧容器 ----
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    info "停止旧容器..."
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" down 2>/dev/null || true
fi

# ---- 启动容器 ----
info "启动 OpenClaw Desktop..."
docker compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" up -d 2>&1

# ---- 等待就绪 ----
info "等待服务就绪..."
for i in $(seq 1 30); do
    if docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
        ok "所有服务已启动（${i}s）"
        break
    fi
    [ "$i" -eq 30 ] && warn "等待超时，服务可能仍在启动中"
    sleep 2
done

# ---- 输出连接信息 ----
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  OpenClaw Desktop 安装完成!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  ${CYAN}Web 桌面:${NC}  http://${PUBLIC_IP:-<IP>}:${NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale&quality=6&compression=2"
echo -e "  ${CYAN}VNC:${NC}       vnc://${PUBLIC_IP:-<IP>}:${VNC_PORT}  (密码: ${VNC_PASSWORD})"
echo -e "  ${CYAN}Gateway:${NC}   ws://${PUBLIC_IP:-<IP>}:${GATEWAY_PORT}"
echo ""
echo -e "  ${CYAN}安装目录:${NC}  ${INSTALL_DIR}"
echo -e "  ${CYAN}管理命令:${NC}"
echo "    查看日志:  docker logs -f ${CONTAINER_NAME}"
echo "    重启:      cd ${INSTALL_DIR} && docker compose --env-file .env restart"
echo "    停止:      cd ${INSTALL_DIR} && docker compose --env-file .env down"
echo "    卸载:      cd ${INSTALL_DIR} && docker compose --env-file .env down -v && rm -rf ${INSTALL_DIR}"
echo ""

# ---- 检查注册 ----
sleep 3
REG_LOG=$(docker logs "${CONTAINER_NAME}" 2>&1 | grep -i "register" | tail -3)
if echo "$REG_LOG" | grep -q "Successfully registered"; then
    ok "已自动注册到 Portal，回到个人助理页面即可使用!"
else
    warn "自动注册可能仍在进行中，请稍后在个人助理页面查看连接状态"
    echo "  注册日志: docker logs ${CONTAINER_NAME} 2>&1 | grep register"
fi
echo ""
