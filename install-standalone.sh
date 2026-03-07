#!/usr/bin/env bash
# ============================================================
# OpenClaw Desktop — 独立安装脚本（裸机版）
#
# 适用场景: 个人直接使用 OpenClaw Desktop，无需 Portal
# 安装前交互式收集 AI 模型 API 密钥，启动后即可使用
#
# 用法:
#   curl -fsSL <RAW_URL>/install-standalone.sh | sudo bash
#
# 非交互式:
#   curl -fsSL <RAW_URL>/install-standalone.sh | sudo bash -s -- \
#     --anthropic-key=sk-ant-xxx --openai-key=sk-xxx
#
# 参数:
#   --anthropic-key=KEY    Anthropic API Key
#   --openai-key=KEY       OpenAI API Key
#   --gemini-key=KEY       Google Gemini API Key
#   --openrouter-key=KEY   OpenRouter API Key
#   --ollama-url=URL       Ollama 地址 (默认自动检测本地)
#   --gateway-token=TOKEN  Gateway 访问令牌 (默认自动生成)
#   --public-ip=IP         公网 IP（可选，自动探测）
#   --gateway-port=N       Gateway 端口（默认 18789）
#   --vnc-password=PW      VNC 密码（默认 openclaw）
#   --skip-models          跳过模型配置（稍后手动配置）
#   --non-interactive      非交互模式，跳过所有提示
# ============================================================
set -euo pipefail

# ---- 颜色输出 ----
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
        |_|      Standalone Installer v0.2.0
EOF
    echo -e "${NC}"
}

# ---- 默认值 ----
IMAGE="tencentcloudadpdevrel/openclaw-desktop:latest"
CONTAINER_NAME="openclaw-desktop"
PUBLIC_IP=""
GATEWAY_PORT="18789"
VNC_PORT="5901"
NOVNC_PORT="6080"
VNC_PASSWORD="openclaw"
INSTALL_DIR="/opt/openclaw"
GATEWAY_TOKEN=""
NON_INTERACTIVE=0
SKIP_MODELS=0

# 模型密钥
ANTHROPIC_API_KEY=""
OPENAI_API_KEY=""
GEMINI_API_KEY=""
OPENROUTER_API_KEY=""
MINIMAX_API_KEY=""
MOONSHOT_API_KEY=""
QIANFAN_API_KEY=""
OLLAMA_URL=""

# ---- 解析参数 ----
for arg in "$@"; do
    case "$arg" in
        --anthropic-key=*)  ANTHROPIC_API_KEY="${arg#*=}" ;;
        --openai-key=*)     OPENAI_API_KEY="${arg#*=}" ;;
        --gemini-key=*)     GEMINI_API_KEY="${arg#*=}" ;;
        --openrouter-key=*) OPENROUTER_API_KEY="${arg#*=}" ;;
        --minimax-key=*)    MINIMAX_API_KEY="${arg#*=}" ;;
        --moonshot-key=*)   MOONSHOT_API_KEY="${arg#*=}" ;;
        --qianfan-key=*)    QIANFAN_API_KEY="${arg#*=}" ;;
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
            echo "模型配置:"
            echo "  --anthropic-key=KEY    Anthropic API Key (Claude)"
            echo "  --openai-key=KEY       OpenAI API Key (GPT)"
            echo "  --gemini-key=KEY       Google Gemini API Key"
            echo "  --openrouter-key=KEY   OpenRouter API Key (多模型聚合)"
            echo "  --minimax-key=KEY      MiniMax API Key"
            echo "  --moonshot-key=KEY     Moonshot/Kimi API Key"
            echo "  --qianfan-key=KEY      百度千帆 API Key"
            echo "  --ollama-url=URL       Ollama 服务地址"
            echo ""
            echo "系统配置:"
            echo "  --gateway-token=TOKEN  Gateway 访问令牌 (默认自动生成)"
            echo "  --gateway-port=N       Gateway 端口 (默认 18789)"
            echo "  --vnc-password=PW      VNC 密码 (默认 openclaw)"
            echo "  --public-ip=IP         公网 IP (自动探测)"
            echo ""
            echo "控制:"
            echo "  --skip-models          跳过模型配置"
            echo "  --non-interactive      非交互模式"
            exit 0 ;;
    esac
done

# ---- 交互式读取（对 pipe 输入兼容） ----
read_input() {
    local prompt="$1" default="${2:-}" var_name="$3"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        eval "$var_name=\"$default\""
        return
    fi
    # 尝试从 /dev/tty 读取（即使 stdin 是 pipe）
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
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        return
    fi
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
    local _input=""
    if [ -t 0 ] || [ -e /dev/tty ]; then
        if [ "$default" = "y" ]; then
            ask "${prompt} [Y/n]: "
        else
            ask "${prompt} [y/N]: "
        fi
        read -r _input < /dev/tty 2>/dev/null || _input=""
        _input="${_input:-$default}"
        case "$_input" in
            [Yy]*) return 0 ;;
            *) return 1 ;;
        esac
    else
        [ "$default" = "y" ] && return 0 || return 1
    fi
}

# ===========================================================
# 第一阶段: 交互式模型配置收集
# ===========================================================
collect_model_config() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  AI 模型配置${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  OpenClaw 支持多种 AI 模型提供商，至少需要配置一个。"
    echo -e "  ${DIM}密钥会安全存储在服务器本地，不会上传到任何地方。${NC}"
    echo ""

    # --- Anthropic ---
    echo -e "${BOLD}  1. Anthropic (Claude)${NC}"
    echo -e "     ${DIM}推荐 — Claude Opus/Sonnet 系列，编程和推理能力强${NC}"
    echo -e "     ${DIM}获取: https://console.anthropic.com/settings/keys${NC}"
    if [ -z "$ANTHROPIC_API_KEY" ]; then
        read_secret "     API Key (sk-ant-...，回车跳过)" ANTHROPIC_API_KEY
    else
        echo -e "     ${GREEN}✓ 已通过命令行参数提供${NC}"
    fi
    echo ""

    # --- OpenAI ---
    echo -e "${BOLD}  2. OpenAI (GPT)${NC}"
    echo -e "     ${DIM}GPT-4o/GPT-5 系列${NC}"
    echo -e "     ${DIM}获取: https://platform.openai.com/api-keys${NC}"
    if [ -z "$OPENAI_API_KEY" ]; then
        read_secret "     API Key (sk-...，回车跳过)" OPENAI_API_KEY
    else
        echo -e "     ${GREEN}✓ 已通过命令行参数提供${NC}"
    fi
    echo ""

    # --- Google Gemini ---
    echo -e "${BOLD}  3. Google Gemini${NC}"
    echo -e "     ${DIM}Gemini Pro/Flash 系列，有免费额度${NC}"
    echo -e "     ${DIM}获取: https://aistudio.google.com/apikey${NC}"
    if [ -z "$GEMINI_API_KEY" ]; then
        read_secret "     API Key (回车跳过)" GEMINI_API_KEY
    else
        echo -e "     ${GREEN}✓ 已通过命令行参数提供${NC}"
    fi
    echo ""

    # --- OpenRouter ---
    echo -e "${BOLD}  4. OpenRouter (多模型聚合)${NC}"
    echo -e "     ${DIM}一个 Key 访问多个模型（Claude, GPT, Gemini, Llama 等）${NC}"
    echo -e "     ${DIM}获取: https://openrouter.ai/keys${NC}"
    if [ -z "$OPENROUTER_API_KEY" ]; then
        read_secret "     API Key (sk-or-...，回车跳过)" OPENROUTER_API_KEY
    else
        echo -e "     ${GREEN}✓ 已通过命令行参数提供${NC}"
    fi
    echo ""

    # --- 国内模型 ---
    if read_yesno "  是否配置国内模型提供商？(MiniMax/Moonshot/百度千帆)" "n"; then
        echo ""

        echo -e "${BOLD}  5. MiniMax${NC}"
        echo -e "     ${DIM}获取: https://platform.minimaxi.com${NC}"
        if [ -z "$MINIMAX_API_KEY" ]; then
            read_secret "     API Key (回车跳过)" MINIMAX_API_KEY
        fi
        echo ""

        echo -e "${BOLD}  6. Moonshot / Kimi${NC}"
        echo -e "     ${DIM}获取: https://platform.moonshot.cn${NC}"
        if [ -z "$MOONSHOT_API_KEY" ]; then
            read_secret "     API Key (回车跳过)" MOONSHOT_API_KEY
        fi
        echo ""

        echo -e "${BOLD}  7. 百度千帆 (文心一言)${NC}"
        echo -e "     ${DIM}获取: https://qianfan.cloud.baidu.com${NC}"
        if [ -z "$QIANFAN_API_KEY" ]; then
            read_secret "     API Key (回车跳过)" QIANFAN_API_KEY
        fi
        echo ""
    fi

    # --- Ollama (本地模型) ---
    echo -e "${BOLD}  本地模型 (Ollama)${NC}"
    # 自动检测 Ollama
    if curl -fsSL --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        ok "检测到本地 Ollama 服务"
        OLLAMA_URL="http://host.docker.internal:11434"
        local models_json
        models_json=$(curl -fsSL --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null || echo "{}")
        local model_names
        model_names=$(echo "$models_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(m['name'] for m in d.get('models',[])))" 2>/dev/null || echo "")
        if [ -n "$model_names" ]; then
            echo -e "     ${DIM}已安装模型: ${model_names}${NC}"
        fi
    else
        if [ -z "$OLLAMA_URL" ]; then
            echo -e "     ${DIM}未检测到本地 Ollama。如有远程 Ollama，请输入地址${NC}"
            read_input "     Ollama URL (回车跳过)" "" OLLAMA_URL
        fi
    fi
    echo ""

    # --- 汇总 ---
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  配置汇总${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local configured=0
    [ -n "$ANTHROPIC_API_KEY" ]  && echo -e "  ${GREEN}✓${NC} Anthropic (Claude)"     && configured=$((configured+1))
    [ -n "$OPENAI_API_KEY" ]     && echo -e "  ${GREEN}✓${NC} OpenAI (GPT)"           && configured=$((configured+1))
    [ -n "$GEMINI_API_KEY" ]     && echo -e "  ${GREEN}✓${NC} Google Gemini"           && configured=$((configured+1))
    [ -n "$OPENROUTER_API_KEY" ] && echo -e "  ${GREEN}✓${NC} OpenRouter"              && configured=$((configured+1))
    [ -n "$MINIMAX_API_KEY" ]    && echo -e "  ${GREEN}✓${NC} MiniMax"                 && configured=$((configured+1))
    [ -n "$MOONSHOT_API_KEY" ]   && echo -e "  ${GREEN}✓${NC} Moonshot/Kimi"           && configured=$((configured+1))
    [ -n "$QIANFAN_API_KEY" ]    && echo -e "  ${GREEN}✓${NC} 百度千帆"                && configured=$((configured+1))
    [ -n "$OLLAMA_URL" ]         && echo -e "  ${GREEN}✓${NC} Ollama (${OLLAMA_URL})"  && configured=$((configured+1))

    if [ "$configured" -eq 0 ]; then
        echo ""
        warn "未配置任何模型提供商！"
        echo -e "  ${DIM}你可以稍后在 ~/.openclaw/.env 或 /opt/openclaw/.env 中手动添加 API Key${NC}"
        echo ""
        if ! read_yesno "  是否继续安装（不带模型配置）？" "y"; then
            echo "安装已取消。"
            exit 0
        fi
    else
        echo ""
        ok "已配置 ${configured} 个模型提供商"
    fi
    echo ""
}

# ===========================================================
# 主流程
# ===========================================================
banner

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

# ---- 收集模型配置（安装 Docker 之前，让用户先完成配置） ----
if [ "$SKIP_MODELS" -eq 0 ]; then
    collect_model_config
fi

# ---- 生成 Gateway Token ----
if [ -z "$GATEWAY_TOKEN" ]; then
    if has_cmd openssl; then
        GATEWAY_TOKEN=$(openssl rand -hex 32)
    else
        GATEWAY_TOKEN=$(head -c 32 /dev/urandom | xxd -p 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-')
    fi
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

# Firefox 进程调优 — 小规格机器更激进
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
    VNC_RES="1920x1080"; PROFILE="large"
elif [ "$TUNED_CPUS" -ge 4 ] && [ "$TUNED_MEM_GB" -ge 8 ]; then
    VNC_RES="1600x900"; PROFILE="medium"
elif [ "$TUNED_MEM_GB" -le 3 ]; then
    VNC_RES="1280x720"; PROFILE="tiny"
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
    [ -n "$PUBLIC_IP" ] && ok "公网 IP: $PUBLIC_IP" || warn "无法探测公网 IP"
fi

# ---- 生成配置文件 ----
info "创建安装目录: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/shared" "${INSTALL_DIR}/screenshots" "${INSTALL_DIR}/openclaw-config"

# 生成 .env（系统 + 模型密钥）
cat > "${INSTALL_DIR}/.env" <<EOF
# Auto-generated by OpenClaw Standalone Installer
# ---- 系统配置 ----
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
PUBLIC_IP=${PUBLIC_IP}

# ---- Gateway 认证 ----
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}

# ---- AI 模型 API Keys ----
EOF

# 逐个写入非空的 API Key
[ -n "$ANTHROPIC_API_KEY" ]  && echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$OPENAI_API_KEY" ]     && echo "OPENAI_API_KEY=${OPENAI_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$GEMINI_API_KEY" ]     && echo "GEMINI_API_KEY=${GEMINI_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$OPENROUTER_API_KEY" ] && echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$MINIMAX_API_KEY" ]    && echo "MINIMAX_API_KEY=${MINIMAX_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$MOONSHOT_API_KEY" ]   && echo "MOONSHOT_API_KEY=${MOONSHOT_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$QIANFAN_API_KEY" ]    && echo "QIANFAN_API_KEY=${QIANFAN_API_KEY}" >> "${INSTALL_DIR}/.env"
[ -n "$OLLAMA_URL" ]         && echo "OLLAMA_BASE_URL=${OLLAMA_URL}" >> "${INSTALL_DIR}/.env"

# 生成 openclaw.json 基础配置
cat > "${INSTALL_DIR}/openclaw-config/openclaw.json" <<CEOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": ${GATEWAY_PORT},
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  }
}
CEOF

# 同步 .env 到 openclaw-config 目录，让容器内 OpenClaw 也能读取
cp "${INSTALL_DIR}/.env" "${INSTALL_DIR}/openclaw-config/.env"

# 生成 docker-compose.yml
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
      - OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN:-}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - GEMINI_API_KEY=${GEMINI_API_KEY:-}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
      - MINIMAX_API_KEY=${MINIMAX_API_KEY:-}
      - MOONSHOT_API_KEY=${MOONSHOT_API_KEY:-}
      - QIANFAN_API_KEY=${QIANFAN_API_KEY:-}
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-}
    security_opt:
      - seccomp=unconfined
    cap_add:
      - SYS_ADMIN
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - desktop-home:/root
      - ./shared:/shared
      - screenshots:/screenshots
      - ./openclaw-config:/root/.openclaw
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
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  OpenClaw Desktop 安装完成!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Web 桌面 (推荐):${NC}"
echo -e "  ${CYAN}http://${PUBLIC_IP:-<IP>}:${NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale&quality=6&compression=2${NC}"
echo ""
echo -e "  ${BOLD}VNC 客户端:${NC}"
echo -e "  vnc://${PUBLIC_IP:-<IP>}:${VNC_PORT}  密码: ${VNC_PASSWORD}"
echo ""
echo -e "  ${BOLD}Gateway (用于 IDE/API 连接):${NC}"
echo -e "  ws://${PUBLIC_IP:-<IP>}:${GATEWAY_PORT}"
echo -e "  Token: ${GATEWAY_TOKEN}"
echo ""
echo -e "  ${BOLD}安装目录:${NC} ${INSTALL_DIR}"
echo ""
echo -e "  ${BOLD}管理命令:${NC}"
echo "    查看日志:  docker logs -f ${CONTAINER_NAME}"
echo "    重启:      cd ${INSTALL_DIR} && docker compose --env-file .env restart"
echo "    停止:      cd ${INSTALL_DIR} && docker compose --env-file .env down"
echo "    卸载:      cd ${INSTALL_DIR} && docker compose --env-file .env down -v && rm -rf ${INSTALL_DIR}"
echo ""
echo -e "  ${BOLD}配置修改:${NC}"
echo "    API Key:   编辑 ${INSTALL_DIR}/.env，然后重启容器"
echo "    高级配置:  编辑 ${INSTALL_DIR}/openclaw-config/openclaw.json"
echo ""

# ---- 验证 Gateway 连通性 ----
sleep 2
GW_HEALTH=$(curl -fsSL --max-time 5 "http://127.0.0.1:${GATEWAY_PORT}/healthz" 2>/dev/null || echo "")
if [ -n "$GW_HEALTH" ]; then
    ok "Gateway 运行正常"
else
    warn "Gateway 可能仍在启动中，请稍后检查: curl http://localhost:${GATEWAY_PORT}/healthz"
fi

echo ""
echo -e "${DIM}提示: 你可以在 IDE 中使用 Gateway Token 连接到这台远程 OpenClaw 桌面。${NC}"
echo ""
