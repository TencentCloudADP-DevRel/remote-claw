#!/bin/bash
set -euo pipefail

HOSTNAME=$(hostname)
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
OPENCLAW_CONFIG="/root/.openclaw/openclaw.json"
REGISTRATION_STATE_FILE="/root/.openclaw/portal-registration.json"
AUTO_TUNE_MARKER_START='// OPENCLAW_AUTO_TUNE_START'
AUTO_TUNE_MARKER_END='// OPENCLAW_AUTO_TUNE_END'

# ============================================
# Firefox 自动调优
# ============================================
apply_firefox_autotune() {
    local profile_dir="$1"
    local user_js="${profile_dir}/user.js"
    local ff_proc ff_webiso ff_cache_mem

    ff_proc="${FIREFOX_PROCESS_COUNT:-4}"
    ff_webiso="${FIREFOX_WEB_ISOLATED_COUNT:-2}"
    ff_cache_mem="${FIREFOX_CACHE_MEMORY_KB:-131072}"

    [ -d "$profile_dir" ] || return 0
    touch "$user_js"
    local tmp_file
    tmp_file="$(mktemp)"

    awk -v start="$AUTO_TUNE_MARKER_START" -v end="$AUTO_TUNE_MARKER_END" '
        $0 == start { skip=1; next }
        $0 == end { skip=0; next }
        skip != 1 { print }
    ' "$user_js" > "$tmp_file"

    cat >> "$tmp_file" <<EOF
$AUTO_TUNE_MARKER_START
user_pref("dom.ipc.processCount", ${ff_proc});
user_pref("dom.ipc.processCount.webIsolated", ${ff_webiso});
user_pref("dom.ipc.processCount.webIsolated.maxPerOrigin", 1);
user_pref("browser.cache.memory.capacity", ${ff_cache_mem});
user_pref("layout.frame_rate", 30);
$AUTO_TUNE_MARKER_END
EOF

    mv "$tmp_file" "$user_js"
}

# ============================================
# 恢复主题配置（volume 挂载会覆盖 /root）
# ============================================
mkdir -p /root/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p /root/.config/gtk-3.0

if [ ! -f /root/.config/gtk-3.0/settings.ini ]; then
    cp -r /opt/openclaw/dotfiles/. /root/
fi

mkdir -p /root/.mozilla/firefox/openclaw.default
cp -r /opt/openclaw/dotfiles/.mozilla/. /root/.mozilla/ 2>/dev/null || true
apply_firefox_autotune "/root/.mozilla/firefox/openclaw.default"

for profile_dir in /root/.mozilla/firefox/*.default-release; do
    if [ -d "$profile_dir" ]; then
        cp /opt/openclaw/dotfiles/.mozilla/firefox/openclaw.default/user.js "$profile_dir/user.js" 2>/dev/null || true
        apply_firefox_autotune "$profile_dir"
    fi
done

# ============================================
# VNC 密码 + xstartup
# ============================================
mkdir -p /root/.vnc
echo "$VNC_PW" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

cat > /root/.vnc/xstartup << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
export DBUS_SESSION_BUS_ADDRESS=
export XDG_SESSION_TYPE=x11
eval $(dbus-launch --sh-syntax)
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null &
exec startxfce4
XEOF
chmod +x /root/.vnc/xstartup

# ============================================
# 启动 VNC
# ============================================
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

echo ">> Starting VNC server on :1 (${VNC_RESOLUTION}x${VNC_COL_DEPTH})"
/usr/bin/Xtigervnc :1 \
    -geometry "$VNC_RESOLUTION" \
    -depth "$VNC_COL_DEPTH" \
    -rfbport ${VNC_PORT} \
    -localhost 0 \
    -SecurityTypes VncAuth \
    -PasswordFile /root/.vnc/passwd \
    -AlwaysShared \
    -AcceptKeyEvents 1 \
    -AcceptPointerEvents 1 \
    -SendCutText 1 \
    -AcceptCutText 1 \
    -auth /root/.Xauthority \
    -desktop "openclaw:1 (root)" &
XVNC_PID=$!

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [ -e /proc/$XVNC_PID ] && netstat -tln 2>/dev/null | grep -q ":${VNC_PORT} "; then
        echo ">> VNC server ready (${i}s)"
        break
    fi
    sleep 1
done
sleep 1

# 启动桌面
(
    unset SESSION_MANAGER
    export DBUS_SESSION_BUS_ADDRESS=
    export XDG_SESSION_TYPE=x11
    eval $(dbus-launch --sh-syntax)
    xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null &
    exec startxfce4
) &
sleep 2

# 剪贴板桥接
autocutsel -s PRIMARY -fork 2>/dev/null || true
autocutsel -s CLIPBOARD -fork 2>/dev/null || true

# ============================================
# 启动 noVNC
# ============================================
echo ">> Starting noVNC on port ${NOVNC_PORT}"
/opt/noVNC/utils/novnc_proxy \
    --vnc localhost:${VNC_PORT} \
    --listen ${NOVNC_PORT} \
    --web /opt/noVNC &

for i in 1 2 3 4 5 6 7 8 9 10; do
    if netstat -tln 2>/dev/null | grep -q ":${NOVNC_PORT} "; then
        echo ">> noVNC ready (${i}s)"
        break
    fi
    sleep 1
done

# ============================================
# 确保 openclaw.json 配置正确
# ============================================
ensure_gateway_config() {
    local token="${OPENCLAW_GATEWAY_TOKEN:-}"
    local config_dir
    config_dir="$(dirname "$OPENCLAW_CONFIG")"
    mkdir -p "$config_dir"

    # 通过环境变量传递敏感数据，避免 shell 引号注入
    OPENCLAW_CFG_PATH="$OPENCLAW_CONFIG" \
    OPENCLAW_CFG_TOKEN="$token" \
    OPENCLAW_CFG_PORT="$GATEWAY_PORT" \
    python3 -c "
import json, os, secrets

cfg_path = os.environ['OPENCLAW_CFG_PATH']
token = os.environ.get('OPENCLAW_CFG_TOKEN', '')
port = int(os.environ.get('OPENCLAW_CFG_PORT', '18789'))

# 读取已有配置或创建新配置
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        cfg = json.load(f)
else:
    cfg = {}

gw = cfg.setdefault('gateway', {})
gw['mode'] = 'local'
gw['bind'] = 'lan'
gw['port'] = port

auth = gw.setdefault('auth', {})
auth['mode'] = 'token'
# 优先使用环境变量 token；否则保留已有 token；都没有则自动生成
if token:
    auth['token'] = token
elif not auth.get('token'):
    auth['token'] = secrets.token_hex(24)

cfg.setdefault('tools', {})['profile'] = 'full'

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null || true
}

ensure_gateway_config

append_gateway_candidate() {
    local candidate="$1"
    [ -n "$candidate" ] || return 0

    case "${candidate}" in
        ws://*|wss://*|http://*|https://*) ;;
        *) candidate="ws://${candidate}" ;;
    esac

    case "
${GATEWAY_CANDIDATES}
" in
        *"
${candidate}
"*) return 0 ;;
    esac

    if [ -z "${GATEWAY_CANDIDATES}" ]; then
        GATEWAY_CANDIDATES="${candidate}"
    else
        GATEWAY_CANDIDATES="${GATEWAY_CANDIDATES}
${candidate}"
    fi
}

collect_gateway_candidates() {
    GATEWAY_CANDIDATES=""

    if [ -n "${PUBLIC_GATEWAY_URL:-}" ]; then
        append_gateway_candidate "${PUBLIC_GATEWAY_URL}"
    fi

    if [ -n "${PUBLIC_IP:-}" ]; then
        append_gateway_candidate "ws://${PUBLIC_IP}:${GATEWAY_PORT}"
    fi

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        append_gateway_candidate "ws://${ip}:${GATEWAY_PORT}"
    done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.' | grep -v '^172\.17\.' || true)
}

write_registration_state() {
    local gateway_url="$1"
    REG_STATE_PATH="${REGISTRATION_STATE_FILE}" \
    REG_PORTAL_URL="${PORTAL_URL}" \
    REG_GATEWAY_URL="${gateway_url}" \
    REG_HOSTNAME="${HOSTNAME}" \
    python3 -c "
import json, os, time

path = os.environ['REG_STATE_PATH']
payload = {
    'portalUrl': os.environ.get('REG_PORTAL_URL', ''),
    'gatewayUrl': os.environ.get('REG_GATEWAY_URL', ''),
    'hostname': os.environ.get('REG_HOSTNAME', ''),
    'registeredAt': int(time.time()),
}
with open(path, 'w') as f:
    json.dump(payload, f, indent=2)
"
}

register_with_portal() {
    local payload="$1"
    curl -sS --max-time 15 -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${PORTAL_URL}/api/openclaw/personal/connect" 2>/dev/null || echo ""
}

# ============================================
# 启动 OpenClaw Gateway
# ============================================
echo ">> Starting OpenClaw Gateway on port ${GATEWAY_PORT}..."
nohup openclaw gateway --port "${GATEWAY_PORT}" > /tmp/gateway.log 2>&1 &

GATEWAY_READY=0
for i in $(seq 1 60); do
    if netstat -tln 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
        GATEWAY_READY=1
        echo ">> OpenClaw Gateway started successfully (${i}s)"
        break
    fi
    sleep 1
done
if [ "$GATEWAY_READY" -eq 0 ]; then
    echo ">> Warning: Gateway not responding after 60s, check /tmp/gateway.log"
fi

# ============================================
# Portal 自动注册（如提供了 REGISTER_TOKEN）
# ============================================
if [ -n "${REGISTER_TOKEN:-}" ] && [ -n "${PORTAL_URL:-}" ]; then
    if [ -f "${REGISTRATION_STATE_FILE}" ] && [ "${FORCE_PORTAL_REGISTRATION:-0}" != "1" ]; then
        echo ">> Portal registration already completed, skipping"
    else
        echo ">> Auto-registering with Portal: ${PORTAL_URL}"

        GW_AUTH_TOKEN=""
        if [ -f "$OPENCLAW_CONFIG" ]; then
            GW_AUTH_TOKEN=$(python3 -c "
import json
with open('$OPENCLAW_CONFIG') as f:
    cfg = json.load(f)
print(cfg.get('gateway', {}).get('auth', {}).get('token', ''))
" 2>/dev/null || echo "")
        fi

        GW_PUBLIC_IP="${PUBLIC_IP:-}"
        if [ -z "$GW_PUBLIC_IP" ] && [ -z "${PUBLIC_GATEWAY_URL:-}" ]; then
            GW_PUBLIC_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
        fi

        collect_gateway_candidates
        PRIMARY_GATEWAY_URL="$(printf '%s\n' "${GATEWAY_CANDIDATES}" | head -n 1 | tr -d '\r')"

        if [ -n "$GW_AUTH_TOKEN" ] && [ -n "$PRIMARY_GATEWAY_URL" ]; then
            REGISTER_PAYLOAD=$(GW_PRIMARY_URL="${PRIMARY_GATEWAY_URL}" \
                GW_CANDIDATES="${GATEWAY_CANDIDATES}" \
                GW_AUTH_TOKEN="${GW_AUTH_TOKEN}" \
                GW_REGISTER_TOKEN="${REGISTER_TOKEN}" \
                GW_HOSTNAME="${HOSTNAME}" \
                python3 -c "
import json, os

candidates = [item for item in os.environ.get('GW_CANDIDATES', '').splitlines() if item]
payload = {
    'registerToken': os.environ['GW_REGISTER_TOKEN'],
    'gatewayUrl': os.environ['GW_PRIMARY_URL'],
    'gatewayUrlCandidates': candidates,
    'authToken': os.environ['GW_AUTH_TOKEN'],
    'name': os.environ.get('GW_HOSTNAME', 'openclaw'),
}
print(json.dumps(payload))
")

            REGISTER_RESULT="$(register_with_portal "${REGISTER_PAYLOAD}")"
            REGISTER_HTTP_CODE="$(printf '%s\n' "${REGISTER_RESULT}" | tail -n 1)"
            REGISTER_BODY="$(printf '%s\n' "${REGISTER_RESULT}" | sed '$d')"

            if [ "${REGISTER_HTTP_CODE}" = "200" ] && printf '%s' "${REGISTER_BODY}" | grep -q '"success":true'; then
                echo ">> Successfully registered with Portal!"
                write_registration_state "${PRIMARY_GATEWAY_URL}"
            elif [ "${REGISTER_HTTP_CODE}" = "409" ] && printf '%s' "${REGISTER_BODY}" | grep -q '"pairingRequired":true'; then
                REQUEST_ID="$(printf '%s' "${REGISTER_BODY}" | python3 -c "import json,sys; print((json.load(sys.stdin).get('requestId') or '').strip())" 2>/dev/null || true)"
                if [ -n "${REQUEST_ID}" ]; then
                    echo ">> Pairing approval required, approving locally..."
                    APPROVE_RESULT="$(openclaw devices approve "${REQUEST_ID}" --json 2>/dev/null || true)"
                    if printf '%s' "${APPROVE_RESULT}" | grep -q '"requestId"'; then
                        RETRY_RESULT="$(register_with_portal "${REGISTER_PAYLOAD}")"
                        RETRY_HTTP_CODE="$(printf '%s\n' "${RETRY_RESULT}" | tail -n 1)"
                        RETRY_BODY="$(printf '%s\n' "${RETRY_RESULT}" | sed '$d')"
                        if [ "${RETRY_HTTP_CODE}" = "200" ] && printf '%s' "${RETRY_BODY}" | grep -q '"success":true'; then
                            echo ">> Successfully registered with Portal after approval!"
                            write_registration_state "${PRIMARY_GATEWAY_URL}"
                        else
                            echo ">> Warning: Portal registration retry failed: ${RETRY_BODY}"
                        fi
                    else
                        echo ">> Warning: local pairing approval failed"
                    fi
                else
                    echo ">> Warning: pairing required but requestId missing"
                fi
            else
                echo ">> Warning: Portal registration failed: ${REGISTER_BODY}"
            fi
        else
            echo ">> Warning: missing auth token or gateway URL candidates, skipping Portal registration"
        fi
    fi
fi

# ============================================
# 截图测试
# ============================================
sleep 3
echo ">> Testing screenshot capability..."
if /opt/openclaw/screenshot.sh /screenshots/boot.png 2>/dev/null; then
    echo ">> Screenshot OK: /screenshots/boot.png"
else
    echo ">> Warning: screenshot test failed (desktop may still be loading)"
fi

# ============================================
# 输出连接信息
# ============================================
cat << INFO

========================================
  Remote OpenClaw Desktop is ready!
========================================

  VNC:      vnc://HOST:${VNC_PORT}
            password: ${VNC_PW}

  Web:
    http://HOST:${NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale&quality=6&compression=2

  Gateway:  ws://HOST:${GATEWAY_PORT}

========================================

INFO

echo ">> All services started. Waiting for Xtigervnc (PID $XVNC_PID)..."
wait $XVNC_PID 2>/dev/null || sleep infinity
