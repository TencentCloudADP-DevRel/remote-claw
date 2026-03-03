# Remote OpenClaw 踩坑记录

## 1. 容器反复重启：VNC 日志文件找不到

**现象**：容器启动后状态为 `Restarting`，日志显示：

```
tail: cannot open '/root/.vnc/*:1.log' for reading: No such file or directory
tail: no files remaining
```

**原因**：

两个问题叠加：

1. `startup.sh` 最后用 `tail -f /root/.vnc/*:1.log` 保持前台运行，但 shell glob `*` 在文件不存在时不会展开，直接报错退出，容器就挂了。
2. `docker-compose.yml` 中把 `desktop-home` volume 挂载到了 `/root`，这会覆盖掉构建阶段写入 `/root` 下的所有文件（包括主题配置），同时 VNC 日志路径也受影响。

**解决**：

- `tail -f` 改用具体的 hostname 拼接路径 `"/root/.vnc/${HOSTNAME}:1.log"`，找不到时 fallback 到 `sleep infinity`。
- 主题配置文件构建时先存到 `/opt/openclaw/dotfiles/`，启动脚本中检测到 `/root` 下没有配置时再拷贝过去。

```bash
# startup.sh 中的修复
VNC_LOG="/root/.vnc/${HOSTNAME}:1.log"
if [ -f "$VNC_LOG" ]; then
    tail -f "$VNC_LOG"
else
    sleep infinity
fi
```

---

## 2. Firefox 无法启动：Failed to execute default Web Browser

**现象**：在桌面里点击打开浏览器，弹窗提示：

```
Failed to execute default Web Browser.
Input/output error.
```

**原因**：

Ubuntu 22.04 的 `apt install firefox` 装的不是真正的 Firefox，而是一个 **snap 过渡包**（transitional package）。它只是一个 shell 脚本，实际会调用 `snap install firefox`。但 Docker 容器里没有 snapd 服务，所以 Firefox 根本无法运行。

验证：

```bash
$ cat /usr/bin/firefox
# 输出显示它只是个 wrapper，要求 snap install firefox

$ dpkg -l | grep firefox
# 显示: Transitional package - firefox -> firefox snap
```

**解决**：

使用 Mozilla 官方 PPA 安装真正的 deb 版 Firefox：

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:mozillateam/ppa \
    && printf 'Package: *\nPin: release o=LP-PPA-mozillateam\nPin-Priority: 1001\n' \
       > /etc/apt/preferences.d/mozilla-firefox \
    && apt-get update && apt-get install -y --no-install-recommends firefox \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
```

关键点是设置 `Pin-Priority: 1001`，让 PPA 的 firefox 包优先级高于 Ubuntu 官方仓库的 snap 过渡包。

---

## 3. docker compose 命令不识别

**现象**：

```bash
$ docker compose up -d --build
unknown shorthand flag: 'd' in -d
```

**原因**：

Docker Engine 虽然是 v28.4.0，但没有安装 Docker Compose V2 插件（`docker-compose-plugin`）。`docker compose`（带空格）是 V2 插件子命令，不是独立二进制。

**解决**：

手动安装 Compose CLI 插件：

```bash
mkdir -p /usr/libexec/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose
```

验证：

```bash
$ docker compose version
Docker Compose version v5.1.0
```

---

## 4. Volume 挂载覆盖构建阶段的配置文件

**现象**：Xfce 主题没生效，桌面是默认外观而不是 Arc-Dark。

**原因**：

`docker-compose.yml` 中 `desktop-home:/root` 把一个空的 named volume 挂载到了 `/root`，这会完全遮盖掉 Dockerfile 构建阶段写入 `/root/.config/` 下的所有 Xfce 主题配置。

Docker 的行为：首次创建 named volume 时会从镜像拷贝内容，但如果 volume 已存在（比如重建容器但不删 volume），旧内容会保留，新的配置不会同步过去。

**解决**：

采用"双份存储"策略：

1. **构建时**：配置文件写入 `/opt/openclaw/dotfiles/`（不受 volume 影响）
2. **启动时**：`startup.sh` 检测 `/root/.config` 是否存在配置，不存在则从 `/opt/openclaw/dotfiles/` 拷贝

```bash
# startup.sh
if [ ! -f /root/.config/gtk-3.0/settings.ini ]; then
    cp -r /opt/openclaw/dotfiles/. /root/
fi
```

这样既保证首次启动有正确的主题，也不会覆盖用户后续的手动修改。

---

## 5. Mozilla PPA 的 GPG 密钥导入失败

**现象**：Dockerfile 构建时报错：

```
subprocess.CalledProcessError: Command '['gpg', ... '--import']' returned non-zero exit status 2.
softwareproperties.shortcuthandler.ShortcutException: ...
```

**原因**：

`add-apt-repository ppa:mozillateam/ppa` 在 Docker 构建环境中导入 GPG 密钥不稳定，`gpg --import` 失败（可能是缺少 gpg-agent 或网络问题）。

**解决**：

不走 PPA，改用 Mozilla 官方 APT 仓库（`packages.mozilla.org`），直接下载签名密钥文件：

```dockerfile
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
```

这种方式不依赖 `add-apt-repository`，不需要 `software-properties-common`，更轻量也更可靠。

---

## 6. 构建时磁盘空间不足（no space left on device）

**现象**：npm install openclaw 成功，但后续写入 npm 缓存时报错：

```
write /root/.npm/_cacache/...: no space left on device
```

**原因**：

Docker 构建过程中每个 `RUN` 指令都会生成一个新的镜像层。npm install 产生大量缓存文件写入 `/root/.npm/`，撑满了 Docker 的存储空间（尤其是有很多旧镜像占用的情况下）。

**解决**：

两步：

1. 清理宿主机 Docker 旧镜像和构建缓存释放空间：

```bash
docker builder prune -f
docker image prune -f
```

2. Dockerfile 中 npm install 后立即清缓存，减小镜像层体积：

```dockerfile
RUN npm install -g openclaw@latest \
    && npm cache clean --force \
    && rm -rf /root/.npm /tmp/*
```

---

## 7. OpenClaw gateway 启动失败 / Dashboard 打不开

**现象**：在容器桌面 Firefox 中打开 `http://127.0.0.1:18789/overview`，报错：

```
Unable to connect
Firefox can't establish a connection to the server at 127.0.0.1:18789.
```

**原因**：

两层问题：

### 7a. Gateway 进程没在运行

`curl -fsSL https://openclaw.ai/install.sh | bash` 安装脚本在安装结束时会临时启动一次 gateway 并打印 dashboard URL，但这是个一次性前台进程。安装流程结束后进程退出，18789 端口不再监听。用户拿到 URL 去访问时，服务已经没了。

### 7b. Gateway 模式未配置

手动执行 `openclaw gateway` 时，如果没有配置过 `gateway.mode`，OpenClaw 出于安全考虑会拒绝启动：

```
Gateway start blocked: set gateway.mode=local (current: unset) or pass --allow-unconfigured.
```

**解决**：

1. 先设置 gateway 模式为 local：

```bash
openclaw config set gateway.mode local
```

2. 后台启动 gateway：

```bash
openclaw gateway --port 18789
```

3. 确认端口监听正常后再用 Firefox 访问：

```bash
netstat -tlnp | grep 18789
# 应看到: tcp 127.0.0.1:18789 LISTEN openclaw-gatew

firefox http://127.0.0.1:18789/overview
```

**注意**：容器重启后 gateway 需要重新启动。如需自动启动，可将上述命令加入 `startup.sh`。

---

## 8. 容器磁盘 94% 满 + 浏览器卡顿

**现象**：容器内 Firefox 频繁卡死，页面加载缓慢。`df -h` 显示容器磁盘仅剩 3GB。

**原因**：

服务器有两块盘：
- `/dev/vda1` 系统盘 100GB（剩余 64GB，大量闲置）
- `/dev/vdb` 数据盘 50GB（Docker Root Dir `/data/docker/lib` 在此盘上）

Docker 所有镜像、容器、volume 全部挤在 50GB 的数据盘上。加上积累的废弃资源：
- 7 个已停止容器写入层：~2.1GB
- 6 个悬空（dangling）镜像：~3.9GB
- `youtu-graphrag` 镜像：7.14GB（不再使用）
- 容器 shm 仅 1GB，Firefox 多标签页时共享内存不足

**解决**：

1. 清理已停止容器：

```bash
docker rm busy_fermat sharp_perlman magical_wilbur wonderful_carver zealous_saha blissful_cartwright sweet_goldstine
```

2. 清理悬空镜像和不用的大镜像：

```bash
docker image prune -f    # 删除所有 dangling 镜像
docker rmi tencentcloudadpdevrel/youtu-graphrag:v1  # 删除 7.14GB 的废弃镜像
```

3. 更新 `docker-compose.yml`，加上资源限制和更大的 shm：

```yaml
shm_size: "2g"      # 1g → 2g，缓解浏览器共享内存不足
mem_limit: 8g       # 限制容器最多用 8GB（宿主机 16GB 留一半）
cpus: 6             # 限制 6 核（宿主机 8 核留 2 核）
```

4. 重启容器使配置生效：

```bash
cd /root/remote-openclaw && docker compose up -d
```

**效果**：

| 指标 | 清理前 | 清理后 |
|------|--------|--------|
| `/data` 盘使用率 | 94%（剩 3GB） | 71%（剩 14GB） |
| 容器内可用磁盘 | 3GB | 14GB |
| 回收空间 | - | ~11GB |
| 容器内存上限 | 无限制 | 8GB |
| shm 大小 | 1GB | 2GB |

**备注**：若后续磁盘再次紧张，可考虑将 Docker Root Dir 迁移到系统盘 `/dev/vda1`（剩余 64GB）。

---

## 9. Firefox 沙盒崩溃 + Tab Crashed

**现象**：

Firefox 报错 `CanCreateUserNamespace() clone() failure: EPERM`，标签页频繁 "Tab Crashed"。OpenClaw agent 反馈无法在容器内运行图形浏览器。

**原因**：

两层问题叠加：

### 9a. clone() EPERM — 用户命名空间被禁止

Docker 容器默认不允许 `clone()` 创建用户命名空间（安全限制），而 Firefox 的内容进程沙盒（content sandbox）依赖此系统调用隔离每个标签页。沙盒创建失败 → 标签页进程直接崩溃。

### 9b. Tab Crashed — 无 GPU + 默认配置太重

Firefox 默认配置假设有 GPU 和充裕内存：
- **8 个内容进程**：每个 200-400MB，容器内轻松吃掉 2-3GB
- **WebGL 开启**：无 GPU 时软件模拟极慢，频繁超时崩溃
- **硬件加速开启**：容器无 GPU，WebRender 回退到 CPU 软渲染，CPU 爆满导致其他进程被饿死
- **动画/遥测/安全浏览等后台服务**：在容器内全是浪费

**解决**：

1. 禁用 Firefox 沙盒（三处确保生效）：

**初始临时方案**（已废弃）：通过 `MOZ_DISABLE_CONTENT_SANDBOX=1` 禁用沙箱。能解决崩溃但会触发腾讯云安全告警。

**最终方案**：通过 Docker 安全配置让容器支持用户命名空间，Firefox 沙箱正常开启：

```yaml
# docker-compose.yml
security_opt:
  - seccomp=unconfined      # 允许 clone(CLONE_NEWUSER)
cap_add:
  - SYS_ADMIN               # Firefox content sandbox 需要
```

同时移除所有沙箱禁用配置：
- 删除 `MOZ_DISABLE_CONTENT_SANDBOX=1` 环境变量
- 删除 `user.js` 中的 `security.sandbox.content.level=0` / `security.sandbox.gpu.level=0`
- 删除 `/etc/profile.d/firefox-sandbox.sh`

2. 创建低资源 Firefox 配置（`user.js`）：

路径：`/root/.mozilla/firefox/openclaw.default/user.js`

```javascript
// 限制内容进程数（默认8→2）
user_pref("dom.ipc.processCount", 2);
user_pref("dom.ipc.processCount.webIsolated", 1);

// 禁用硬件加速（无GPU环境）
user_pref("layers.acceleration.disabled", true);
user_pref("gfx.webrender.all", false);
user_pref("gfx.webrender.enabled", false);
user_pref("gfx.canvas.accelerated", false);

// 禁用 WebGL（无GPU时崩溃元凶）
user_pref("webgl.disabled", true);

// 降低内存 + 禁用无用服务
user_pref("browser.cache.memory.capacity", 65536);
user_pref("browser.sessionhistory.max_total_viewers", 2);
user_pref("toolkit.cosmeticAnimations.enabled", false);
```

配置同时持久化到 `/opt/openclaw/dotfiles/.mozilla/` 防止容器重建丢失。

**注意**：之前尝试用 lighthouse-ci 的 `seccomp-chrome.json` 替换整个 seccomp profile，但该文件是纯白名单模式（`defaultAction: SCMP_ACT_ERRNO`），缺少 Xfce/VNC 需要的 `pthread_create` 等系统调用，导致容器重启循环。正确做法是 `seccomp=unconfined` + `cap_add: SYS_ADMIN`。

**效果**：Firefox 沙箱正常开启，不再触发安全告警，内存占用从 ~1.5GB 降到 ~400-600MB，标签页稳定性显著提升。

---

## 10. Docker 数据盘迁移（/data → 系统盘）

**现象**：容器磁盘反复紧张，清理后仍只有 15GB 可用。

**原因**：

Docker Root Dir 配置在 50GB 的数据盘 `/data/docker/lib/`，而 100GB 的系统盘 `/dev/vda1` 剩余 64GB 完全闲置。

```
/dev/vda1  100GB  系统盘  剩余 64GB ← 闲置
/dev/vdb    50GB  数据盘  剩余 15GB ← Docker 全挤在这里
```

**解决**：

1. 停止 Docker：

```bash
systemctl stop docker docker.socket
```

2. 用 rsync 拷贝数据（保留权限、硬链接、xattr）：

```bash
mkdir -p /var/lib/docker
rsync -aHAXxS /data/docker/lib/ /var/lib/docker/
```

3. 修改 `/etc/docker/daemon.json`：

```json
"data-root": "/var/lib/docker"
```

4. 启动 Docker：

```bash
systemctl start docker
```

5. 验证后可删除旧数据释放数据盘空间：

```bash
# 确认所有容器正常后再删
rm -rf /data/docker/lib/
```

**效果**：

| 指标 | 迁移前 | 迁移后 |
|------|--------|--------|
| 容器可用磁盘 | 15GB（/data 50GB盘） | 55GB（/ 100GB盘） |
| 数据盘 /data | 可释放 | 完全空闲 |
