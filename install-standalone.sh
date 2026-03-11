#!/usr/bin/env bash
# ============================================================
# OpenClaw Remote — 独立安装脚本
#
# 两种模式:
#   simple — 只装 openclaw gateway（无桌面）
#   gui    — openclaw gateway + Xfce 桌面 + VNC + noVNC
#
# 用法:
#   # GUI 模式（默认）
#   curl -fsSL <RAW_URL>/install-standalone.sh | sudo bash
#
#   # 简单模式（只有 gateway）
#   curl -fsSL <RAW_URL>/install-standalone.sh | sudo bash -s -- --mode=simple
#
#   # 非交互式
#   curl -fsSL <RAW_URL>/install-standalone.sh | sudo bash -s -- \
#     --anthropic-key=sk-ant-xxx --openai-key=sk-xxx
#
# 参数:
#   --mode=simple|gui       安装模式（默认 gui）
#   --anthropic-key=KEY     Anthropic API Key
#   --openai-key=KEY        OpenAI API Key
#   --gemini-key=KEY        Google Gemini API Key
#   --openrouter-key=KEY    OpenRouter API Key
#   --ollama-url=URL        Ollama 地址
#   --gateway-token=TOKEN   Gateway 访问令牌（默认自动生成）
#   --gateway-port=N        Gateway 端口（默认 18789）
#   --public-ip=IP          公网 IP（自动探测）
#   --vnc-password=PW       VNC 密码（默认 openclaw，仅 gui 模式）
#   --skip-models           跳过模型配置
#   --non-interactive       非交互模式
# ============================================================
set -euo pipefail

# ---- 颜色 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }
ask()   { echo -en "${CYAN}[?]${NC}    $*"; }

banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
   ____                    ____ _
  / __ \_ __  ___ _ __   / ___| | __ ___      __
 | |  | | '_ \/ _ \ '_ \| |   | |/ _` \ \ /\ / /
 | |__| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \____/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
        |_|      Remote Installer v0.3.0
EOF
    echo -e "${NC}"
}

# ---- 默认值 ----
INSTALL_MODE="gui"
GATEWAY_PORT="18789"
VNC_PASSWORD="openclaw"
INSTALL_DIR="/opt/openclaw"
GATEWAY_TOKEN=""
PUBLIC_IP=""
NON_INTERACTIVE=0
SKIP_MODELS=0

# 镜像
# GUI 模式使用我们的桌面镜像（含 VNC + 桌面 + openclaw）
# Simple 模式也使用相同镜像但不启动桌面，只运行 gateway
# 注：openclaw 官方 Docker 镜像需自行构建，不提供公开预构建镜像
IMAGE_GUI="tencentcloudadpdevrel/openclaw-desktop:latest"
IMAGE_SIMPLE="tencentcloudadpdevrel/openclaw-desktop:latest"

# 模型密钥
ANTHROPIC_API_KEY=""
OPENAI_API_KEY=""
GEMINI_API_KEY=""
OPENROUTER_API_KEY=""
OLLAMA_URL=""

# ---- 解析参数 ----
for arg in "$@"; do
    case "$arg" in
        --mode=*)           INSTALL_MODE="${arg#*=}" ;;
        --anthropic-key=*)  ANTHROPIC_API_KEY="${arg#*=}" ;;
        --openai-key=*)     OPENAI_API_KEY="${arg#*=}" ;;
        --gemini-key=*)     GEMINI_API_KEY="${arg#*=}" ;;
        --openrouter-key=*) OPENROUTER_API_KEY="${arg#*=}" ;;
        --ollama-url=*)     OLLAMA_URL="${arg#*=}" ;;
        --gateway-token=*)  GATEWAY_TOKEN="${arg#*=}" ;;
        --public-ip=*)      PUBLIC_IP="${arg#*=}" ;;
        --gateway-port=*)   GATEWAY_PORT="${arg#*=}" ;;
        --vnc-password=*)   VNC_PASSWORD="${arg#*=}" ;;
        --skip-models)      SKIP_MODELS=1 ;;
        --non-interactive)  NON_INTERACTIVE=1 ;;
        --help|-h)
            banner
            echo "用法: bash install-standalone.sh [选项]"
            echo ""
            echo "模式:"
            echo "  --mode=simple    只安装 openclaw gateway（无桌面）"
            echo "  --mode=gui       安装 gateway + 桌面环境（默认）"
            echo ""
            echo "模型配置:"
            echo "  --anthropic-key=KEY    Anthropic API Key (Claude)"
            echo "  --openai-key=KEY       OpenAI API Key (GPT)"
            echo "  --gemini-key=KEY       Google Gemini API Key"
            echo "  --openrouter-key=KEY   OpenRouter API Key"
            echo "  --ollama-url=URL       Ollama 服务地址"
            echo ""
            echo "系统配置:"
            echo "  --gateway-token=TOKEN  Gateway 访问令牌（默认自动生成）"
            echo "  --gateway-port=N       Gateway 端口（默认 18789）"
            echo "  --vnc-password=PW      VNC 密码（默认 openclaw，仅 gui 模式）"
            echo "  --public-ip=IP         公网 IP（自动探测）"
            echo ""
            echo "控制:"
            echo "  --skip-models          跳过模型配置"
            echo "  --non-interactive      非交互模式"
            exit 0 ;;
    esac
done

# 校验模式
case "$INSTALL_MODE" in
    simple|gui) ;;
    *) err "无效模式: $INSTALL_MODE（可选: simple, gui）"; exit 1 ;;
esac

# ---- 交互式输入 ----
read_input() {
    local prompt="$1" default="${2:-}" var_name="$3"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        eval "$var_name=\"$default\""
        return
    fi
    if [ -t 0 ] || [ -e /dev/tty ]; then
        if [ -n "$default" ]; then
            ask "${prompt} [${DIM}${default}${NC}]: "
            read -r _input < /dev/tty 2>/dev/null || _input=""
            eval "$var_name=\"${_input:-$default}\""
        else
            ask "${prompt}: "
            read -r _input < /dev/tty 2>/dev/null || _input=""
            eval "$var_name=\"$_input\""
        fi
    else
        eval "$var_name=\"$default\""
    fi
}

read_secret() {
    local prompt="$1" var_name="$2"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then return; fi
    if [ -t 0 ] || [ -e /dev/tty ]; then
        ask "${prompt}: "
        read -rs _input < /dev/tty 2>/dev/null || _input=""
        echo ""
        eval "$var_name=\"$_input\""
    fi
}

read_yesno() {
    local prompt="$1" default="${2:-y}"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    if [ -t 0 ] || [ -e /dev/tty ]; then
        if [ "$default" = "y" ]; then ask "${prompt} [Y/n]: "; else ask "${prompt} [y/N]: "; fi
        read -r _input < /dev/tty 2>/dev/null || _input=""
        _input="${_input:-$default}"
        case "$_input" in [Yy]*) return 0 ;; *) return 1 ;; esac
    else
        [ "$default" = "y" ] && return 0 || return 1
    fi
}

# ===========================================================
# 收集模型 API Key
# ===========================================================
collect_model_config() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  AI 模型配置${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  至少需要配置一个模型提供商。密钥安全存储在服务器本地。"
    echo ""

    echo -e "${BOLD}  1. Anthropic (Claude)${NC} ${DIM}— 推荐，获取: https://console.anthropic.com/settings/keys${NC}"
    if [ -z "$ANTHROPIC_API_KEY" ]; then
        read_secret "     API Key (sk-ant-...，回车跳过)" ANTHROPIC_API_KEY
    else
        echo -e "     ${GREEN}✓ 已提供${NC}"
    fi
    echo ""

    echo -e "${BOLD}  2. OpenAI (GPT)${NC} ${DIM}— 获取: https://platform.openai.com/api-keys${NC}"
    if [ -z "$OPENAI_API_KEY" ]; then
        read_secret "     API Key (sk-...，回车跳过)" OPENAI_API_KEY
    else
        echo -e "     ${GREEN}✓ 已提供${NC}"
    fi
    echo ""

    echo -e "${BOLD}  3. Google Gemini${NC} ${DIM}— 获取: https://aistudio.google.com/apikey${NC}"
    if [ -z "$GEMINI_API_KEY" ]; then
        read_secret "     API Key (回车跳过)" GEMINI_API_KEY
    else
        echo -e "     ${GREEN}✓ 已提供${NC}"
    fi
    echo ""

    echo -e "${BOLD}  4. OpenRouter${NC} ${DIM}— 多模型聚合，获取: https://openrouter.ai/keys${NC}"
    if [ -z "$OPENROUTER_API_KEY" ]; then
        read_secret "     API Key (sk-or-...，回车跳过)" OPENROUTER_API_KEY
    else
        echo -e "     ${GREEN}✓ 已提供${NC}"
    fi
    echo ""

    # Ollama 自动检测
    if curl -fsSL --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        ok "检测到本地 Ollama 服务"
        OLLAMA_URL="http://host.docker.internal:11434"
    elif [ -z "$OLLAMA_URL" ]; then
        echo -e "  ${DIM}Ollama: 未检测到。如有远程 Ollama，请输入地址${NC}"
        read_input "  Ollama URL (回车跳过)" "" OLLAMA_URL
    fi

    # 汇总
    echo ""
    local configured=0
    [ -n "$ANTHROPIC_API_KEY" ]  && echo -e "  ${GREEN}✓${NC} Anthropic"  && configured=$((configured+1))
    [ -n "$OPENAI_API_KEY" ]     && echo -e "  ${GREEN}✓${NC} OpenAI"     && configured=$((configured+1))
    [ -n "$GEMINI_API_KEY" ]     && echo -e "  ${GREEN}✓${NC} Gemini"     && configured=$((configured+1))
    [ -n "$OPENROUTER_API_KEY" ] && echo -e "  ${GREEN}✓${NC} OpenRouter" && configured=$((configured+1))
    [ -n "$OLLAMA_URL" ]         && echo -e "  ${GREEN}✓${NC} Ollama"     && configured=$((configured+1))

    if [ "$configured" -eq 0 ]; then
        warn "未配置任何模型。可以稍后通过环境变量添加。"
        if ! read_yesno "  继续安装？" "y"; then exit 0; fi
    else
        ok "已配置 ${configured} 个模型提供商"
    fi
    echo ""
}

# ===========================================================
# 主流程
# ===========================================================
banner

if [ "$INSTALL_MODE" = "gui" ]; then
    info "安装模式: GUI（Gateway + 桌面环境）"
else
    info "安装模式: Simple（仅 Gateway）"
fi

# ---- 检测系统 ----
info "检测系统环境..."
has_cmd() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
ARCH="$(uname -m)"
[ "$OS" != "Linux" ] && err "仅支持 Linux（检测到: $OS）" && exit 1

HOST_CPUS="$(nproc)"
MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1024 / 1024 ))
DISK_FREE_GB=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')

ok "系统: $OS $ARCH | CPU: ${HOST_CPUS}核 | 内存: ${MEM_TOTAL_GB}GB | 磁盘: ${DISK_FREE_GB}GB"

[ "$MEM_TOTAL_GB" -lt 1 ] && err "内存不足" && exit 1
[ "${DISK_FREE_GB:-0}" -lt 5 ] && warn "磁盘空间不足 5GB"

# ---- root 检查 ----
[ "$(id -u)" -ne 0 ] && err "请用 root 或 sudo 运行" && exit 1

# ---- 收集 API Key ----
if [ "$SKIP_MODELS" -eq 0 ]; then
    collect_model_config
fi

# ---- 生成 Token ----
if [ -z "$GATEWAY_TOKEN" ]; then
    if has_cmd openssl; then
        GATEWAY_TOKEN=$(openssl rand -hex 32)
    else
        GATEWAY_TOKEN=$(head -c 32 /dev/urandom | xxd -p 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-')
    fi
fi

# ---- Docker ----
ensure_docker() {
    if has_cmd docker && docker info >/dev/null 2>&1; then
        ok "Docker: $(docker --version | head -1)"
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
    info "安装 Docker Compose..."
    if has_cmd apt-get; then apt-get install -y -qq docker-compose-plugin
    elif has_cmd dnf; then dnf install -y -q docker-compose-plugin
    elif has_cmd yum; then yum install -y -q docker-compose-plugin
    fi
fi

# ---- 探测公网 IP ----
if [ -z "$PUBLIC_IP" ]; then
    info "探测公网 IP..."
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || echo "")
    [ -n "$PUBLIC_IP" ] && ok "公网 IP: $PUBLIC_IP" || warn "无法探测公网 IP"
fi

# ---- 自动调优（仅 GUI 模式需要） ----
clamp() { local v="$1" lo="$2" hi="$3"; [ "$v" -lt "$lo" ] && echo "$lo" && return; [ "$v" -gt "$hi" ] && echo "$hi" && return; echo "$v"; }

if [ "$INSTALL_MODE" = "gui" ]; then
    info "自动调优..."
    TUNED_CPUS=$(clamp $(( HOST_CPUS - 1 )) 2 12)
    TUNED_MEM_GB=$(clamp $(( MEM_TOTAL_GB * 60 / 100 )) 2 24)
    TUNED_SHM_GB=$(clamp $(( TUNED_MEM_GB / 4 )) 1 8)

    if [ "$TUNED_MEM_GB" -le 4 ]; then
        FF_PROC=1; FF_WEBISO=1; FF_CACHE_KB=32768
    elif [ "$TUNED_MEM_GB" -le 8 ]; then
        FF_PROC=2; FF_WEBISO=1; FF_CACHE_KB=65536
    else
        FF_PROC=$(clamp $(( TUNED_CPUS / 2 )) 2 8)
        FF_WEBISO=$(clamp $(( FF_PROC / 2 )) 1 4)
        FF_CACHE_KB=$(clamp $(( TUNED_MEM_GB * 1024 * 1024 / 16 )) 65536 524288)
    fi

    if [ "$TUNED_CPUS" -ge 8 ] && [ "$TUNED_MEM_GB" -ge 16 ]; then
        VNC_RES="1920x1080"
    elif [ "$TUNED_CPUS" -ge 4 ] && [ "$TUNED_MEM_GB" -ge 8 ]; then
        VNC_RES="1600x900"
    elif [ "$TUNED_MEM_GB" -le 3 ]; then
        VNC_RES="1280x720"
    else
        VNC_RES="1366x768"
    fi
    ok "CPU: ${TUNED_CPUS} | 内存: ${TUNED_MEM_GB}GB | 分辨率: ${VNC_RES}"
fi

# ---- 生成配置文件 ----
info "创建安装目录: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/openclaw-config"

# .env 文件
cat > "${INSTALL_DIR}/.env" <<EOF
# Auto-generated by OpenClaw Remote Installer
OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
PUBLIC_IP=${PUBLIC_IP}
EOF

# 写入 API Key 环境变量（非空才写）
[ -n "$ANTHROPIC_API_KEY" ]  && echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$OPENAI_API_KEY" ]     && echo "OPENAI_API_KEY=${OPENAI_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$GEMINI_API_KEY" ]     && echo "GEMINI_API_KEY=${GEMINI_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$OPENROUTER_API_KEY" ] && echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$OLLAMA_URL" ]         && echo "OLLAMA_BASE_URL=${OLLAMA_URL}" >> "${INSTALL_DIR}/.env"

# GUI 模式额外配置
if [ "$INSTALL_MODE" = "gui" ]; then
    cat >> "${INSTALL_DIR}/.env" <<EOF
OPENCLAW_VNC_PORT=5901
OPENCLAW_NOVNC_PORT=6080
OPENCLAW_VNC_PASSWORD=${VNC_PASSWORD}
OPENCLAW_VNC_RESOLUTION=${VNC_RES}
OPENCLAW_VNC_DEPTH=24
OPENCLAW_CPUS=${TUNED_CPUS}
OPENCLAW_MEM_LIMIT=${TUNED_MEM_GB}g
OPENCLAW_SHM_SIZE=${TUNED_SHM_GB}g
OPENCLAW_FIREFOX_PROCESS_COUNT=${FF_PROC}
OPENCLAW_FIREFOX_WEB_ISOLATED_COUNT=${FF_WEBISO}
OPENCLAW_FIREFOX_CACHE_MEMORY_KB=${FF_CACHE_KB}
EOF
fi

# 生成 docker-compose.yml（根据模式不同）
if [ "$INSTALL_MODE" = "gui" ]; then
    IMAGE="${IMAGE_GUI}"
    CONTAINER_NAME="openclaw-desktop"

    cat > "${INSTALL_DIR}/docker-compose.yml" <<'DEOF'
services:
  openclaw:
    image: tencentcloudadpdevrel/openclaw-desktop:latest
    container_name: openclaw-desktop
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
      - OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN:-}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - GEMINI_API_KEY=${GEMINI_API_KEY:-}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-}
    security_opt:
      - seccomp=unconfined
    cap_add:
      - SYS_ADMIN
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - desktop-home:/root
      - ./openclaw-config:/root/.openclaw
    shm_size: "${OPENCLAW_SHM_SIZE:-2g}"
    mem_limit: "${OPENCLAW_MEM_LIMIT:-8g}"
    cpus: ${OPENCLAW_CPUS:-4}

volumes:
  desktop-home:
    driver: local
DEOF

else
    # Simple 模式 — 使用桌面镜像但只启动 gateway（不启动 VNC/桌面）
    IMAGE="${IMAGE_SIMPLE}"
    CONTAINER_NAME="openclaw-gateway"

    cat > "${INSTALL_DIR}/docker-compose.yml" <<'DEOF'
services:
  openclaw:
    image: tencentcloudadpdevrel/openclaw-desktop:latest
    container_name: openclaw-gateway
    hostname: openclaw
    init: true
    restart: unless-stopped
    ports:
      - "${OPENCLAW_GATEWAY_PORT:-18789}:${OPENCLAW_GATEWAY_PORT:-18789}"
    environment:
      - GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT:-18789}
      - OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN:-}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - GEMINI_API_KEY=${GEMINI_API_KEY:-}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-}
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./openclaw-config:/root/.openclaw
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}/healthz"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    entrypoint: ["openclaw"]
    command: ["gateway", "--bind", "lan", "--port", "${OPENCLAW_GATEWAY_PORT:-18789}"]
DEOF
fi

ok "配置文件已生成"

# ---- 拉取镜像 ----
info "拉取镜像: ${IMAGE}..."
docker pull "${IMAGE}" 2>&1 | tail -5
ok "镜像拉取完成"

# ---- 停止旧容器 ----
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    info "停止旧容器..."
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" down 2>/dev/null || true
fi

# ---- 在容器内运行 onboard 配置（simple 模式） ----
if [ "$INSTALL_MODE" = "simple" ]; then
    info "运行 openclaw onboard 配置 gateway..."

    # 构建 onboard 参数
    ONBOARD_ARGS=(
        onboard
        --non-interactive
        --mode local
        --no-install-daemon
        --skip-channels
        --skip-skills
        --skip-health
        --skip-ui
        --gateway-bind lan
        --gateway-port 18789
        --gateway-auth token
        --gateway-token "$GATEWAY_TOKEN"
    )

    # 添加 API key 参数
    [ -n "$ANTHROPIC_API_KEY" ]  && ONBOARD_ARGS+=(--anthropic-api-key "$ANTHROPIC_API_KEY")
    [ -n "$OPENAI_API_KEY" ]     && ONBOARD_ARGS+=(--openai-api-key "$OPENAI_API_KEY")
    [ -n "$GEMINI_API_KEY" ]     && ONBOARD_ARGS+=(--gemini-api-key "$GEMINI_API_KEY")
    [ -n "$OPENROUTER_API_KEY" ] && ONBOARD_ARGS+=(--openrouter-api-key "$OPENROUTER_API_KEY")

    # 如果有 API key 就选第一个可用的 auth-choice
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        ONBOARD_ARGS+=(--auth-choice apiKey)
    elif [ -n "$OPENAI_API_KEY" ]; then
        ONBOARD_ARGS+=(--auth-choice openai-api-key)
    elif [ -n "$GEMINI_API_KEY" ]; then
        ONBOARD_ARGS+=(--auth-choice gemini-api-key)
    elif [ -n "$OPENROUTER_API_KEY" ]; then
        ONBOARD_ARGS+=(--auth-choice openrouter-api-key)
    else
        ONBOARD_ARGS+=(--auth-choice skip)
    fi

    # 运行 onboard（用 run --rm 临时容器）
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" \
        run --rm --entrypoint openclaw openclaw "${ONBOARD_ARGS[@]}" 2>&1 || {
            warn "onboard 未完全成功，使用回退配置"
            # 回退：手动写最小配置
            cat > "${INSTALL_DIR}/openclaw-config/openclaw.json" <<FALLBACK
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": ${GATEWAY_PORT},
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "tools": {
    "profile": "full"
  }
}
FALLBACK
        }
fi

# ---- GUI 模式：生成初始配置文件 ----
if [ "$INSTALL_MODE" = "gui" ]; then
    # GUI 模式在容器内通过 startup.sh 运行 onboard
    # 这里先写一份最小配置确保 gateway 能启动
    if [ ! -f "${INSTALL_DIR}/openclaw-config/openclaw.json" ]; then
        cat > "${INSTALL_DIR}/openclaw-config/openclaw.json" <<GEOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": ${GATEWAY_PORT},
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "tools": {
    "profile": "full"
  }
}
GEOF
    fi
fi

# ---- 启动 ----
info "启动 OpenClaw..."
docker compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" up -d 2>&1

# ---- 等待就绪 ----
info "等待服务就绪..."
for i in $(seq 1 30); do
    if docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
        ok "服务已启动（${i}s）"
        break
    fi
    [ "$i" -eq 30 ] && warn "等待超时，服务可能仍在启动中"
    sleep 2
done

# ---- 输出连接信息 ----
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  OpenClaw 安装完成!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""

echo -e "  ${BOLD}Gateway (IDE/API 连接):${NC}"
echo -e "  ${CYAN}ws://${PUBLIC_IP:-<IP>}:${GATEWAY_PORT}${NC}"
echo -e "  Token: ${GATEWAY_TOKEN}"
echo ""

if [ "$INSTALL_MODE" = "gui" ]; then
    echo -e "  ${BOLD}Web 桌面:${NC}"
    echo -e "  ${CYAN}http://${PUBLIC_IP:-<IP>}:6080/vnc.html?autoconnect=true&resize=scale&quality=6&compression=2${NC}"
    echo ""
    echo -e "  ${BOLD}VNC 客户端:${NC}"
    echo -e "  vnc://${PUBLIC_IP:-<IP>}:5901  密码: ${VNC_PASSWORD}"
    echo ""
fi

echo -e "  ${BOLD}安装目录:${NC} ${INSTALL_DIR}"
echo ""
echo -e "  ${BOLD}管理命令:${NC}"
echo "    查看日志:  docker logs -f ${CONTAINER_NAME}"
echo "    重启:      cd ${INSTALL_DIR} && docker compose --env-file .env restart"
echo "    停止:      cd ${INSTALL_DIR} && docker compose --env-file .env down"
echo "    卸载:      cd ${INSTALL_DIR} && docker compose --env-file .env down -v && rm -rf ${INSTALL_DIR}"
echo ""
echo -e "  ${BOLD}修改配置:${NC}"
echo "    API Key:   编辑 ${INSTALL_DIR}/.env 然后重启"
echo "    高级:      编辑 ${INSTALL_DIR}/openclaw-config/openclaw.json"
echo ""

# ---- 验证 ----
sleep 2
GW_HEALTH=$(curl -fsSL --max-time 5 "http://127.0.0.1:${GATEWAY_PORT}/healthz" 2>/dev/null || echo "")
if [ -n "$GW_HEALTH" ]; then
    ok "Gateway 运行正常"
else
    warn "Gateway 可能仍在启动中: curl http://localhost:${GATEWAY_PORT}/healthz"
fi
echo ""
