#!/usr/bin/env bash
#
# Remote OpenClaw — 一键部署脚本
#
# 用法:
#   curl -fsSL <url>/setup.sh | bash
#   或: git clone ... && cd remote-openclaw && bash setup.sh
#
# 功能:
#   1. 检测服务器硬件（CPU/内存/磁盘）
#   2. 检查并安装 Docker（如需要）
#   3. 根据硬件自动生成最优容器配置
#   4. 构建镜像并启动容器
#
set -euo pipefail

# ============================================
# 颜色输出
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }

# ============================================
# 项目路径
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"

# ============================================
# Step 1: 硬件检测
# ============================================
step "检测服务器硬件配置..."

CPU_CORES=$(nproc)
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
TOTAL_MEM_GB=$((TOTAL_MEM_MB / 1024))

# 找最大可用磁盘分区
BEST_DISK=""
BEST_DISK_AVAIL=0
while IFS= read -r line; do
    avail=$(echo "$line" | awk '{print $4}')
    mount=$(echo "$line" | awk '{print $6}')
    avail_gb=$((avail / 1024 / 1024))
    if [ "$avail_gb" -gt "$BEST_DISK_AVAIL" ]; then
        BEST_DISK_AVAIL=$avail_gb
        BEST_DISK="$mount"
    fi
done < <(df -k --output=source,size,used,avail,pcent,target 2>/dev/null \
    | grep '^/dev/' | grep -v 'tmpfs\|overlay')

echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │         服务器硬件检测结果                │"
echo "  ├─────────────────────────────────────────┤"
printf "  │  CPU 核心数:    %-24s│\n" "${CPU_CORES} 核"
printf "  │  总内存:        %-24s│\n" "${TOTAL_MEM_GB} GB (${TOTAL_MEM_MB} MB)"
printf "  │  最大磁盘:      %-24s│\n" "${BEST_DISK} (${BEST_DISK_AVAIL} GB 可用)"
echo "  └─────────────────────────────────────────┘"

# ============================================
# Step 2: 最低配置检查
# ============================================
step "检查最低配置要求..."

MIN_CPU=2
MIN_MEM_GB=4
MIN_DISK_GB=10
PASSED=true

if [ "$CPU_CORES" -lt "$MIN_CPU" ]; then
    err "CPU 核心数不足: ${CPU_CORES} 核 (最低 ${MIN_CPU} 核)"
    PASSED=false
else
    ok "CPU: ${CPU_CORES} 核 (>= ${MIN_CPU})"
fi

if [ "$TOTAL_MEM_GB" -lt "$MIN_MEM_GB" ]; then
    err "内存不足: ${TOTAL_MEM_GB} GB (最低 ${MIN_MEM_GB} GB)"
    PASSED=false
else
    ok "内存: ${TOTAL_MEM_GB} GB (>= ${MIN_MEM_GB})"
fi

if [ "$BEST_DISK_AVAIL" -lt "$MIN_DISK_GB" ]; then
    err "磁盘空间不足: ${BEST_DISK_AVAIL} GB 可用 (最低 ${MIN_DISK_GB} GB)"
    PASSED=false
else
    ok "磁盘: ${BEST_DISK_AVAIL} GB 可用 (>= ${MIN_DISK_GB})"
fi

if [ "$PASSED" != "true" ]; then
    err "服务器配置不满足最低要求，部署中止。"
    exit 1
fi

# ============================================
# Step 3: 根据硬件计算容器资源配额
# ============================================
step "计算最优容器资源配额..."

# 策略: 给容器分配大部分资源，留一些给宿主机
# CPU: 留 2 核给宿主机（最少给容器 2 核）
CONTAINER_CPUS=$((CPU_CORES - 2))
[ "$CONTAINER_CPUS" -lt 2 ] && CONTAINER_CPUS=2
[ "$CONTAINER_CPUS" -gt "$CPU_CORES" ] && CONTAINER_CPUS=$CPU_CORES

# 内存: 留 2-4GB 给宿主机
if [ "$TOTAL_MEM_GB" -le 8 ]; then
    # 小内存机: 留 2GB
    CONTAINER_MEM=$((TOTAL_MEM_GB - 2))
    CONTAINER_SHM=1
elif [ "$TOTAL_MEM_GB" -le 16 ]; then
    # 中等: 留 3GB
    CONTAINER_MEM=$((TOTAL_MEM_GB - 3))
    CONTAINER_SHM=2
elif [ "$TOTAL_MEM_GB" -le 32 ]; then
    # 较大: 留 4GB
    CONTAINER_MEM=$((TOTAL_MEM_GB - 4))
    CONTAINER_SHM=4
else
    # 大内存: 留 6GB
    CONTAINER_MEM=$((TOTAL_MEM_GB - 6))
    CONTAINER_SHM=8
fi

[ "$CONTAINER_MEM" -lt 2 ] && CONTAINER_MEM=2

# VNC 分辨率: 按内存分级
if [ "$TOTAL_MEM_GB" -le 4 ]; then
    VNC_RES="1280x720"
elif [ "$TOTAL_MEM_GB" -le 8 ]; then
    VNC_RES="1600x900"
else
    VNC_RES="1920x1080"
fi

# Docker data-root: 优先使用可用空间最大的盘
if [ "$BEST_DISK" = "/" ]; then
    DOCKER_DATA_ROOT="/var/lib/docker"
else
    DOCKER_DATA_ROOT="${BEST_DISK}/docker/lib"
fi

echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │         容器资源配额                      │"
echo "  ├─────────────────────────────────────────┤"
printf "  │  容器 CPU:      %-24s│\n" "${CONTAINER_CPUS} 核"
printf "  │  容器内存:      %-24s│\n" "${CONTAINER_MEM} GB"
printf "  │  共享内存:      %-24s│\n" "${CONTAINER_SHM} GB"
printf "  │  VNC 分辨率:    %-24s│\n" "${VNC_RES}"
printf "  │  Docker 数据:   %-24s│\n" "${DOCKER_DATA_ROOT}"
echo "  └─────────────────────────────────────────┘"

# ============================================
# Step 4: 检查 & 安装 Docker
# ============================================
step "检查 Docker 环境..."

install_docker() {
    info "正在安装 Docker..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-plugin 2>/dev/null \
            || apt-get install -y -qq docker.io 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y docker docker-compose-plugin 2>/dev/null \
            || yum install -y docker 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y docker docker-compose-plugin 2>/dev/null \
            || dnf install -y docker 2>/dev/null
    else
        err "无法自动安装 Docker，请手动安装后重试。"
        exit 1
    fi
}

if ! command -v docker &>/dev/null; then
    warn "Docker 未安装"
    install_docker
fi

# 确保 Docker daemon 运行
if ! docker info &>/dev/null 2>&1; then
    info "启动 Docker daemon..."
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    sleep 3
    if ! docker info &>/dev/null 2>&1; then
        err "Docker daemon 无法启动，请检查安装。"
        exit 1
    fi
fi

# 确保有 docker compose（v2 插件或独立 docker-compose）
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    info "安装 docker-compose-plugin..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
    fi
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        err "docker compose 不可用，请手动安装。"
        exit 1
    fi
fi

ok "Docker: $(docker --version | head -1)"
ok "Compose: $(${COMPOSE_CMD} version 2>/dev/null | head -1)"

# ============================================
# Step 5: 配置 Docker data-root（如需）
# ============================================
step "配置 Docker 数据目录..."

DAEMON_JSON="/etc/docker/daemon.json"
CURRENT_ROOT=$(docker info 2>/dev/null | grep "Docker Root Dir" | awk '{print $NF}')

if [ "$DOCKER_DATA_ROOT" != "$CURRENT_ROOT" ] && [ "$BEST_DISK" != "/" ]; then
    info "当前 Docker 数据在: ${CURRENT_ROOT}"
    info "建议迁移到: ${DOCKER_DATA_ROOT} (磁盘空间更大)"

    mkdir -p "$DOCKER_DATA_ROOT"

    # 备份并写入 daemon.json
    [ -f "$DAEMON_JSON" ] && cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"

    if [ -f "$DAEMON_JSON" ] && command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    with open('$DAEMON_JSON') as f: cfg = json.load(f)
except: cfg = {}
cfg['data-root'] = '$DOCKER_DATA_ROOT'
with open('$DAEMON_JSON', 'w') as f: json.dump(cfg, f, indent=4)
print('updated')
"
    else
        cat > "$DAEMON_JSON" << DJEOF
{
    "data-root": "${DOCKER_DATA_ROOT}"
}
DJEOF
    fi

    info "重启 Docker daemon..."
    systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
    sleep 3
    ok "Docker 数据目录: ${DOCKER_DATA_ROOT}"
else
    ok "Docker 数据目录: ${CURRENT_ROOT} (无需迁移)"
fi

# ============================================
# Step 6: 生成 docker-compose.yml
# ============================================
step "生成 docker-compose.yml..."

cat > "${PROJECT_DIR}/docker-compose.yml" << COMPEOF
services:
  desktop:
    build: .
    container_name: openclaw-desktop
    hostname: openclaw
    restart: unless-stopped
    ports:
      - "5901:5901"   # VNC
      - "6080:6080"   # noVNC Web
    environment:
      - VNC_PW=openclaw
      - VNC_RESOLUTION=${VNC_RES}
      - VNC_COL_DEPTH=24
    security_opt:
      - seccomp=unconfined
    cap_add:
      - SYS_ADMIN
    volumes:
      - desktop-home:/root
      - ./shared:/shared
      - screenshots:/screenshots
    shm_size: "${CONTAINER_SHM}g"
    mem_limit: ${CONTAINER_MEM}g
    cpus: ${CONTAINER_CPUS}

volumes:
  desktop-home:
    driver: local
  screenshots:
    driver: local
COMPEOF

ok "docker-compose.yml 已生成 (CPU: ${CONTAINER_CPUS} / MEM: ${CONTAINER_MEM}g / SHM: ${CONTAINER_SHM}g / VNC: ${VNC_RES})"

# ============================================
# Step 7: 构建镜像
# ============================================
step "构建 Docker 镜像（首次较慢，请耐心等待）..."

cd "${PROJECT_DIR}"
mkdir -p shared

${COMPOSE_CMD} build --no-cache 2>&1 | while IFS= read -r line; do
    # 只显示关键进度行，减少输出噪音
    case "$line" in
        *"Step"*|*"Successfully"*|*"FINISHED"*|*"#"*"DONE"*)
            echo "  $line"
            ;;
    esac
done

ok "镜像构建完成"

# ============================================
# Step 8: 启动容器
# ============================================
step "启动容器..."

# 清理可能存在的同名旧容器（避免 name conflict）
if docker ps -a --format '{{.Names}}' | grep -q '^openclaw-desktop$'; then
    info "发现已有 openclaw-desktop 容器，先移除..."
    docker rm -f openclaw-desktop 2>/dev/null || true
fi

${COMPOSE_CMD} up -d

sleep 5

if docker ps --filter "name=openclaw-desktop" --format "{{.Status}}" | grep -q "Up"; then
    ok "容器已启动"
else
    err "容器启动失败，请检查: ${COMPOSE_CMD} logs"
    exit 1
fi

# ============================================
# Step 9: 等待服务就绪
# ============================================
step "等待服务就绪..."

# 等 VNC
for i in $(seq 1 30); do
    if docker exec openclaw-desktop bash -c "test -f /root/.vnc/openclaw:1.pid" 2>/dev/null; then
        ok "VNC 服务就绪"
        break
    fi
    [ "$i" -eq 30 ] && warn "VNC 可能还在启动中"
    sleep 2
done

# 等 Gateway
for i in $(seq 1 30); do
    if docker exec openclaw-desktop curl -s -o /dev/null http://127.0.0.1:18789/ 2>/dev/null; then
        ok "OpenClaw Gateway 就绪"
        break
    fi
    [ "$i" -eq 30 ] && warn "Gateway 可能还在启动中，首次运行需要 openclaw configure"
    sleep 2
done

# ============================================
# Step 10: 输出结果
# ============================================
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_IP")

echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║       Remote OpenClaw 部署完成!                   ║"
echo "  ╠═══════════════════════════════════════════════════╣"
echo "  ║                                                   ║"
echo "  ║  noVNC (浏览器访问):                              ║"
echo "  ║    http://${HOST_IP}:6080/vnc.html?autoconnect=true&resize=scale"
echo "  ║                                                   ║"
echo "  ║  VNC 客户端:                                      ║"
echo "  ║    vnc://${HOST_IP}:5901                          ║"
echo "  ║    密码: openclaw                                 ║"
echo "  ║                                                   ║"
echo "  ║  容器配额:                                        ║"
echo "  ║    CPU: ${CONTAINER_CPUS} 核 / 内存: ${CONTAINER_MEM}GB / SHM: ${CONTAINER_SHM}GB"
echo "  ║                                                   ║"
echo "  ╠═══════════════════════════════════════════════════╣"
echo "  ║  首次使用请在容器内运行:                          ║"
echo "  ║    docker exec -it openclaw-desktop bash           ║"
echo "  ║    openclaw configure                              ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
