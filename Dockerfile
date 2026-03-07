FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1920x1080 \
    VNC_COL_DEPTH=24 \
    VNC_PW=openclaw \
    HOME=/root \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ============================================
# 1. 基础依赖 + 中文支持 + Xfce4 桌面 + 主题美化
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales tzdata ca-certificates curl wget git sudo \
    dbus-x11 x11-utils x11-xserver-utils xauth \
    # Xfce4 桌面
    xfce4 xfce4-terminal xfce4-whiskermenu-plugin \
    thunar thunar-archive-plugin mousepad ristretto file-roller \
    # 主题 + 字体
    arc-theme papirus-icon-theme \
    fonts-noto fonts-noto-cjk fonts-noto-color-emoji \
    dmz-cursor-theme gtk2-engines-murrine gtk2-engines-pixbuf \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Firefox 浏览器（Mozilla 官方 APT 仓库，绕过 snap）
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends gnupg \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
       -o /etc/apt/keyrings/packages.mozilla.org.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
       > /etc/apt/sources.list.d/mozilla.list \
    && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1001\n' \
       > /etc/apt/preferences.d/mozilla \
    && apt-get update && apt-get install -y --no-install-recommends firefox \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 3. TigerVNC + noVNC + 截图/自动化工具
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    tigervnc-standalone-server tigervnc-common tigervnc-tools \
    python3 python3-numpy python3-pip python3-pil \
    scrot imagemagick xdotool xclip xsel autocutsel \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/novnc/noVNC.git /opt/noVNC \
    && git clone --depth 1 https://github.com/novnc/websockify.git /opt/noVNC/utils/websockify \
    && ln -s /opt/noVNC/vnc.html /opt/noVNC/index.html \
    && rm -rf /opt/noVNC/.git /opt/noVNC/utils/websockify/.git

# ============================================
# 4. Node.js 22 + OpenClaw + Claude Code + Codex CLI
#    编译工具装完即删，省 ~500MB
# ============================================
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get install -y --no-install-recommends \
       build-essential python3-dev make g++ cmake \
    && npm install -g \
       openclaw@latest \
       @anthropic-ai/claude-code@latest \
       @openai/codex@latest \
    && npm cache clean --force \
    && rm -rf /root/.npm /tmp/* \
    && apt-get purge -y --auto-remove build-essential python3-dev make g++ cmake \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && openclaw --version || true \
    && claude --version || true \
    && codex --version || true

# ============================================
# 5. 实用工具
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    htop nano vim net-tools iputils-ping procps xdg-utils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 6. 截图脚本
# ============================================
RUN mkdir -p /opt/openclaw /screenshots
COPY screenshot.sh /opt/openclaw/screenshot.sh
RUN chmod +x /opt/openclaw/screenshot.sh

# ============================================
# 7. 主题配置（存到 /opt 下，启动时拷贝到 /root）
#    因为 /root 会被 volume 挂载覆盖
# ============================================
RUN mkdir -p /opt/openclaw/dotfiles/.config/xfce4/xfconf/xfce-perchannel-xml \
    && mkdir -p /opt/openclaw/dotfiles/.config/gtk-3.0

# GTK3 → Arc-Dark
RUN printf '[Settings]\n\
gtk-theme-name=Arc-Dark\n\
gtk-icon-theme-name=Papirus-Dark\n\
gtk-cursor-theme-name=DMZ-White\n\
gtk-font-name=Noto Sans 10\n\
gtk-application-prefer-dark-theme=true\n' \
    > /opt/openclaw/dotfiles/.config/gtk-3.0/settings.ini

# Xfce xsettings
RUN printf '<?xml version="1.0" encoding="UTF-8"?>\n\
<channel name="xsettings" version="1.0">\n\
  <property name="Net" type="empty">\n\
    <property name="ThemeName" type="string" value="Arc-Dark"/>\n\
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>\n\
    <property name="CursorThemeName" type="string" value="DMZ-White"/>\n\
  </property>\n\
  <property name="Gtk" type="empty">\n\
    <property name="FontName" type="string" value="Noto Sans 10"/>\n\
    <property name="CursorThemeName" type="string" value="DMZ-White"/>\n\
  </property>\n\
  <property name="Xft" type="empty">\n\
    <property name="Antialias" type="int" value="1"/>\n\
    <property name="HintStyle" type="string" value="hintslight"/>\n\
    <property name="RGBA" type="string" value="rgb"/>\n\
  </property>\n\
</channel>\n' > /opt/openclaw/dotfiles/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml

# Xfce 窗口管理器
RUN printf '<?xml version="1.0" encoding="UTF-8"?>\n\
<channel name="xfwm4" version="1.0">\n\
  <property name="general" type="empty">\n\
    <property name="theme" type="string" value="Arc-Dark"/>\n\
    <property name="title_font" type="string" value="Noto Sans Bold 9"/>\n\
  </property>\n\
</channel>\n' > /opt/openclaw/dotfiles/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml

# 桌面背景色（深蓝灰）
RUN printf '<?xml version="1.0" encoding="UTF-8"?>\n\
<channel name="xfce4-desktop" version="1.0">\n\
  <property name="backdrop" type="empty">\n\
    <property name="screen0" type="empty">\n\
      <property name="monitorVNC-0" type="empty">\n\
        <property name="workspace0" type="empty">\n\
          <property name="color-style" type="int" value="0"/>\n\
          <property name="rgba1" type="array">\n\
            <value type="uint" value="10280"/>\n\
            <value type="uint" value="11308"/>\n\
            <value type="uint" value="13878"/>\n\
            <value type="uint" value="65535"/>\n\
          </property>\n\
          <property name="image-style" type="int" value="0"/>\n\
        </property>\n\
      </property>\n\
    </property>\n\
  </property>\n\
</channel>\n' > /opt/openclaw/dotfiles/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml

# 面板（底部任务栏）
RUN printf '<?xml version="1.0" encoding="UTF-8"?>\n\
<channel name="xfce4-panel" version="1.0">\n\
  <property name="configver" type="int" value="2"/>\n\
  <property name="panels" type="array">\n\
    <value type="int" value="1"/>\n\
    <property name="panel-1" type="empty">\n\
      <property name="position" type="string" value="p=8;x=960;y=1054"/>\n\
      <property name="length" type="uint" value="100"/>\n\
      <property name="position-locked" type="bool" value="true"/>\n\
      <property name="size" type="uint" value="40"/>\n\
      <property name="background-style" type="uint" value="0"/>\n\
      <property name="plugin-ids" type="array">\n\
        <value type="int" value="1"/>\n\
        <value type="int" value="2"/>\n\
        <value type="int" value="3"/>\n\
        <value type="int" value="4"/>\n\
        <value type="int" value="5"/>\n\
      </property>\n\
    </property>\n\
  </property>\n\
  <property name="plugins" type="empty">\n\
    <property name="plugin-1" type="string" value="whiskermenu"/>\n\
    <property name="plugin-2" type="string" value="tasklist"/>\n\
    <property name="plugin-3" type="string" value="separator">\n\
      <property name="expand" type="bool" value="true"/>\n\
      <property name="style" type="uint" value="0"/>\n\
    </property>\n\
    <property name="plugin-4" type="string" value="systray"/>\n\
    <property name="plugin-5" type="string" value="clock"/>\n\
  </property>\n\
</channel>\n' > /opt/openclaw/dotfiles/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml

# ============================================
# 8. Firefox 配置（ioa-max 放宽资源限制）
# ============================================
RUN mkdir -p /opt/openclaw/dotfiles/.mozilla/firefox/openclaw.default \
    && printf '[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default\nIsRelative=1\nPath=openclaw.default\nDefault=1\n' \
       > /opt/openclaw/dotfiles/.mozilla/firefox/profiles.ini \
    && printf '// === Process & rendering (overridden by autotune) ===\n\
user_pref("dom.ipc.processCount", 4);\n\
user_pref("dom.ipc.processCount.webIsolated", 2);\n\
user_pref("dom.ipc.processCount.webIsolated.maxPerOrigin", 1);\n\
// === GPU / compositing — 无 GPU 环境全部关闭 ===\n\
user_pref("layers.acceleration.disabled", true);\n\
user_pref("gfx.webrender.all", false);\n\
user_pref("gfx.webrender.enabled", false);\n\
user_pref("gfx.canvas.accelerated", false);\n\
user_pref("gfx.x11-egl.force-disabled", true);\n\
user_pref("media.hardware-video-decoding.enabled", false);\n\
user_pref("media.ffmpeg.vaapi.enabled", false);\n\
user_pref("webgl.disabled", true);\n\
user_pref("webgl.enable-webgl2", false);\n\
// === Memory / cache ===\n\
user_pref("browser.cache.memory.capacity", 65536);\n\
user_pref("browser.cache.disk.capacity", 256000);\n\
user_pref("browser.cache.memory.max_entry_size", 2048);\n\
user_pref("browser.sessionhistory.max_total_viewers", 1);\n\
user_pref("browser.sessionstore.max_tabs_undo", 3);\n\
user_pref("browser.sessionstore.max_windows_undo", 0);\n\
user_pref("browser.sessionstore.interval", 60000);\n\
user_pref("browser.tabs.unloadOnLowMemory", true);\n\
user_pref("image.mem.decode_bytes_at_a_time", 16384);\n\
user_pref("image.mem.surfacecache.max_size_kb", 131072);\n\
// === Disable background services ===\n\
user_pref("extensions.pocket.enabled", false);\n\
user_pref("browser.safebrowsing.malware.enabled", false);\n\
user_pref("browser.safebrowsing.phishing.enabled", false);\n\
user_pref("datareporting.healthreport.uploadEnabled", false);\n\
user_pref("toolkit.telemetry.enabled", false);\n\
user_pref("toolkit.telemetry.unified", false);\n\
user_pref("toolkit.telemetry.archive.enabled", false);\n\
user_pref("app.update.enabled", false);\n\
user_pref("browser.shell.checkDefaultBrowser", false);\n\
user_pref("browser.search.suggest.enabled", false);\n\
user_pref("browser.urlbar.suggest.searches", false);\n\
user_pref("browser.discovery.enabled", false);\n\
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);\n\
user_pref("browser.newtabpage.activity-stream.telemetry", false);\n\
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);\n\
user_pref("browser.newtabpage.activity-stream.showSponsored", false);\n\
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);\n\
user_pref("network.prefetch-next", false);\n\
user_pref("network.dns.disablePrefetch", true);\n\
user_pref("network.http.speculative-parallel-limit", 0);\n\
user_pref("browser.send_pings", false);\n\
// === Reduce animations / rendering cost ===\n\
user_pref("toolkit.cosmeticAnimations.enabled", false);\n\
user_pref("ui.prefersReducedMotion", 1);\n\
user_pref("layout.frame_rate", 30);\n\
user_pref("nglayout.enable_drag_images", false);\n\
// === Network ===\n\
user_pref("network.dns.disableIPv6", true);\n\
user_pref("security.tls.version.min", 1);\n\
user_pref("security.tls.version.max", 4);\n' \
       > /opt/openclaw/dotfiles/.mozilla/firefox/openclaw.default/user.js

# ============================================
# 9. 启动脚本
# ============================================
COPY startup.sh /opt/startup.sh
RUN chmod +x /opt/startup.sh

EXPOSE 5901 6080 18789

ENTRYPOINT ["/opt/startup.sh"]
