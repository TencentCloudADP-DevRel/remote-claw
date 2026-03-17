# Remote Claw

基于 VPS 资源自动调优并部署 OpenClaw 桌面容器的一键方案。

## 功能概览

- 自动探测主机 CPU / 内存并生成 `.env`
- 自动安装 Docker 与 Docker Compose（缺失时）
- 自动按资源调优容器参数（`cpus` / `mem_limit` / `shm_size`）
- 自动调优 Firefox 多进程与缓存参数
- 一键拉取指定镜像并启动（首次安装）或滚动更新（已有容器）

## 快速开始

### 方式一: 远程一键安装 (推荐) 🚀

在全新服务器上直接运行,无需预先安装 Docker 或 Git:

```bash
curl -fsSL https://raw.githubusercontent.com/TencentCloudADP-DevRel/remote-claw/main/install-standalone.sh | sudo bash
```

**特点:**
- ✅ 自动安装 Docker
- ✅ 自动拉取镜像 `tencentcloudadpdevrel/openclaw-desktop:latest`
- ✅ 自动资源调优
- ✅ 交互式配置 API Key
- ✅ 启动完整桌面环境 (VNC + Gateway)

**非交互式安装:**

```bash
curl -fsSL https://raw.githubusercontent.com/TencentCloudADP-DevRel/remote-claw/main/install-standalone.sh | sudo bash -s -- \
  --image=tencentcloudadpdevrel/openclaw-desktop:latest \
  --anthropic-key=sk-ant-xxx \
  --openai-key=sk-xxx \
  --non-interactive
```

**仅安装 Gateway (无桌面):**

```bash
curl -fsSL https://raw.githubusercontent.com/TencentCloudADP-DevRel/remote-claw/main/install-standalone.sh | sudo bash -s -- --mode=simple
```

### 方式二: 本地部署

如果已经 clone 了项目:

```bash
cd /root/remote-claw
sudo ./autotune-deploy.sh
```

兼容入口（等价）：

```bash
sudo ./setup.sh
```

脚本会自动完成：

- 检测系统资源并写入 `.env`
- 检查并安装 Docker/Compose
- 执行 `docker compose up -d`

## 访问入口

- VNC: `vnc://<服务器IP>:5901`
- noVNC: `http://<服务器IP>:6080/vnc.html?autoconnect=true&resize=scale&quality=6&compression=2&show_dot=true`
- OpenClaw Gateway: `ws://<服务器IP>:18789`

默认端口可在 `.env` 中通过以下变量调整：

- `OPENCLAW_IMAGE`
- `OPENCLAW_VNC_PORT`
- `OPENCLAW_NOVNC_PORT`
- `OPENCLAW_GATEWAY_PORT`

Portal 一键部署模式还会使用：

- `PORTAL_URL`
- `REGISTER_TOKEN`
- `PUBLIC_IP`
- `PUBLIC_GATEWAY_URL`

其中 `PUBLIC_GATEWAY_URL` 可显式指定 Portal 应回连的地址；未提供时，启动脚本会自动组合公网 IP 和本机网卡地址候选列表，并在首次注册时自动尝试配对批准。

如果需要锁定 Docker 版本，可在安装命令中传入 `--image=<registry>/<image>:<tag>`。

## 常用运维命令

查看容器状态：

```bash
docker compose ps
```

查看日志：

```bash
docker compose logs -f
```

手动触发重建更新：

```bash
sudo ./autotune-deploy.sh
```

## 关键文件

- `autotune-deploy.sh`: 主机探测、自动调优、自动部署入口
- `docker-compose.yml`: 容器资源/端口/环境变量定义
- `startup.sh`: 容器内桌面、VNC、noVNC、Gateway 启动流程
- `Dockerfile`: 运行环境镜像定义
- `docs/troubleshooting.md`: 历史问题与排障记录
