#!/bin/bash
set -euo pipefail

HOSTNAME=$(hostname)
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
AUTO_TUNE_MARKER_START='// OPENCLAW_AUTO_TUNE_START'
AUTO_TUNE_MARKER_END='// OPENCLAW_AUTO_TUNE_END'

apply_firefox_autotune() {
    local profile_dir="$1"
    local user_js="${profile_dir}/user.js"
    local tmp_file
    local ff_proc ff_webiso ff_cache_mem

    ff_proc="${FIREFOX_PROCESS_COUNT:-4}"
    ff_webiso="${FIREFOX_WEB_ISOLATED_COUNT:-2}"
    ff_cache_mem="${FIREFOX_CACHE_MEMORY_KB:-131072}"

    [ -d "$profile_dir" ] || return 0
    touch "$user_js"
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
user_pref("browser.cache.memory.capacity", ${ff_cache_mem});
$AUTO_TUNE_MARKER_END
EOF

    mv "$tmp_file" "$user_js"
}

# ============================================
# 恢复主题配置（volume 挂载会覆盖 /root）
# ============================================
mkdir -p /root/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p /root/.config/gtk-3.0

# 恢复桌面主题（不覆盖用户修改）
if [ ! -f /root/.config/gtk-3.0/settings.ini ]; then
    cp -r /opt/openclaw/dotfiles/. /root/
fi

# 恢复 Firefox 配置（同步到所有 profile 目录）
mkdir -p /root/.mozilla/firefox/openclaw.default
cp -r /opt/openclaw/dotfiles/.mozilla/. /root/.mozilla/ 2>/dev/null || true
apply_firefox_autotune "/root/.mozilla/firefox/openclaw.default"

# 将 user.js 同步到 Firefox 自动创建的 default-release profile
for profile_dir in /root/.mozilla/firefox/*.default-release; do
    if [ -d "$profile_dir" ]; then
        cp /opt/openclaw/dotfiles/.mozilla/firefox/openclaw.default/user.js "$profile_dir/user.js" 2>/dev/null || true
        apply_firefox_autotune "$profile_dir"
    fi
done

# ============================================
# VNC 密码设置
# ============================================
mkdir -p /root/.vnc
echo "$VNC_PW" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

# ============================================
# VNC xstartup（含桌面性能优化）
# ============================================
cat > /root/.vnc/xstartup << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11

# Start dbus
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval $(dbus-launch --sh-syntax)
fi

# 关闭 Xfce 合成器（compositing），大幅减少渲染开销
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null &

# Start Xfce
exec startxfce4
XEOF
chmod +x /root/.vnc/xstartup

# ============================================
# 清理可能存在的锁文件
# ============================================
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

# ============================================
# 启动 TigerVNC（直接启动 Xtigervnc，避免 perl wrapper 阻塞）
# ============================================
echo ">> Starting VNC server on :1 (${VNC_RESOLUTION}x${VNC_COL_DEPTH})"

# 直接启动 Xtigervnc 进程（后台）
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

# 等待 VNC 端口就绪
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [ -e /proc/$XVNC_PID ] && netstat -tln 2>/dev/null | grep -q ":${VNC_PORT} "; then
        echo ">> VNC server ready (${i}s)"
        break
    fi
    sleep 1
done
sleep 1

# 启动桌面环境（在 VNC 就绪之后）
(
    unset SESSION_MANAGER
    unset DBUS_SESSION_BUS_ADDRESS
    export XDG_SESSION_TYPE=x11
    if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
        eval $(dbus-launch --sh-syntax)
    fi
    xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null &
    exec startxfce4
) &
sleep 2

# ============================================
# 启动 autocutsel（桥接 X11 剪贴板 ↔ VNC 剪贴板）
# ============================================
autocutsel -s PRIMARY -fork 2>/dev/null || true
autocutsel -s CLIPBOARD -fork 2>/dev/null || true

# ============================================
# 启动 noVNC（Web 访问，带压缩优化）
# ============================================
echo ">> Starting noVNC on port ${NOVNC_PORT}"
/opt/noVNC/utils/novnc_proxy \
    --vnc localhost:${VNC_PORT} \
    --listen ${NOVNC_PORT} \
    --web /opt/noVNC &

# 等待 noVNC 端口就绪
for i in 1 2 3 4 5 6 7 8 9 10; do
    if netstat -tln 2>/dev/null | grep -q ":${NOVNC_PORT} "; then
        echo ">> noVNC ready (${i}s)"
        break
    fi
    sleep 1
done

# ============================================
# 启动 OpenClaw Gateway（后台运行，带重试健康检查）
# ============================================
# 确保 Gateway 监听所有网卡（允许外部 Portal 连接）
if [ -f /root/.openclaw/openclaw.json ]; then
    python3 -c "
import json
with open('/root/.openclaw/openclaw.json') as f:
    cfg = json.load(f)
gw = cfg.setdefault('gateway', {})
gw['bind'] = 'lan'
gw.setdefault('auth', {})['mode'] = 'token'
with open('/root/.openclaw/openclaw.json', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null || true
fi
echo ">> Starting OpenClaw Gateway on port ${GATEWAY_PORT}..."
nohup openclaw gateway --port "${GATEWAY_PORT}" > /tmp/gateway.log 2>&1 &

GATEWAY_READY=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if netstat -tln 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
        GATEWAY_READY=1
        echo ">> OpenClaw Gateway started successfully (${i}s)"
        break
    fi
    sleep 1
done
if [ "$GATEWAY_READY" -eq 0 ]; then
    echo ">> Warning: Gateway not responding after 20s, check /tmp/gateway.log"
fi

# ============================================
# 验证截图工具可用
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

  Web (推荐用这个 URL，已含性能优化参数):
    http://HOST:${NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale&quality=6&compression=2&show_dot=true

  Screenshot:
    Full:   /opt/openclaw/screenshot.sh
    Base64: /opt/openclaw/screenshot.sh --base64
    Custom: /opt/openclaw/screenshot.sh /path/to/output.png

  Automation:
    xdotool - keyboard/mouse control
    xclip   - clipboard access

========================================

INFO

# 保持前台运行（等待 Xtigervnc 进程，如果它退出则容器退出）
echo ">> All services started. Waiting for Xtigervnc (PID $XVNC_PID)..."
wait $XVNC_PID 2>/dev/null || sleep infinity
