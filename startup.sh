#!/bin/bash
set -e

HOSTNAME=$(hostname)

# ============================================
# 恢复主题配置（volume 挂载会覆盖 /root）
# ============================================
mkdir -p /root/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p /root/.config/gtk-3.0

# 恢复桌面主题（不覆盖用户修改）
if [ ! -f /root/.config/gtk-3.0/settings.ini ]; then
    cp -r /opt/openclaw/dotfiles/. /root/
fi

# 恢复 Firefox 低资源配置（独立检查，防止崩溃/卡顿）
if [ ! -f /root/.mozilla/firefox/openclaw.default/user.js ]; then
    mkdir -p /root/.mozilla/firefox/openclaw.default
    cp -r /opt/openclaw/dotfiles/.mozilla/. /root/.mozilla/ 2>/dev/null || true
fi

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
# 启动 TigerVNC（带性能优化参数）
# ============================================
echo ">> Starting VNC server on :1 (${VNC_RESOLUTION}x${VNC_COL_DEPTH})"
vncserver :1 \
    -geometry "$VNC_RESOLUTION" \
    -depth "$VNC_COL_DEPTH" \
    -localhost no \
    -SecurityTypes VncAuth \
    -xstartup /root/.vnc/xstartup \
    -AlwaysShared \
    -AcceptKeyEvents \
    -AcceptPointerEvents \
    -SendCutText \
    -AcceptCutText

sleep 2

# ============================================
# 启动 noVNC（Web 访问，带压缩优化）
# ============================================
echo ">> Starting noVNC on port ${NOVNC_PORT}"
/opt/noVNC/utils/novnc_proxy \
    --vnc localhost:${VNC_PORT} \
    --listen ${NOVNC_PORT} \
    --web /opt/noVNC &

# ============================================
# 注入 noVNC 默认参数（自动高质量压缩 + 性能模式）
# ============================================
cat > /opt/noVNC/app/custom.js << 'JSEOF'
// 自动应用性能优化参数
document.addEventListener('DOMContentLoaded', function() {
    // 这些参数通过 URL query 更可靠，此处作为 fallback
});
JSEOF

# ============================================
# 启动 OpenClaw Gateway（后台运行）
# ============================================
echo ">> Starting OpenClaw Gateway on port 18789..."
nohup openclaw gateway --port 18789 > /tmp/gateway.log 2>&1 &
sleep 2
if curl -s -o /dev/null -w '' http://127.0.0.1:18789/ 2>/dev/null; then
    echo ">> OpenClaw Gateway started successfully"
else
    echo ">> Warning: Gateway may still be starting, check /tmp/gateway.log"
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

# 保持前台运行
VNC_LOG="/root/.vnc/${HOSTNAME}:1.log"
if [ -f "$VNC_LOG" ]; then
    tail -f "$VNC_LOG"
else
    echo ">> VNC log not found at $VNC_LOG, waiting..."
    sleep infinity
fi
