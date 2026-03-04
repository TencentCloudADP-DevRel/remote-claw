# Remote Claw

基于 VPS 资源自动调优并部署 OpenClaw 桌面容器的一键方案。

## 功能概览

- 自动探测主机 CPU / 内存并生成 `.env`
- 自动安装 Docker 与 Docker Compose（缺失时）
- 自动按资源调优容器参数（`cpus` / `mem_limit` / `shm_size`）
- 自动调优 Firefox 多进程与缓存参数
- 一键构建并启动（首次安装）或滚动更新（已有容器）

## 快速开始

1. 进入项目目录：

```bash
cd /root/remote-claw
```

2. 以 root 执行一键部署脚本：

```bash
sudo ./autotune-deploy.sh
```

脚本会自动完成：

- 检测系统资源并写入 `.env`
- 检查并安装 Docker/Compose
- 执行 `docker compose up -d --build`

## 访问入口

- VNC: `vnc://<服务器IP>:5901`
- noVNC: `http://<服务器IP>:6080/vnc.html?autoconnect=true&resize=scale&quality=6&compression=2&show_dot=true`
- OpenClaw Gateway: `ws://<服务器IP>:18789`

默认端口可在 `.env` 中通过以下变量调整：

- `OPENCLAW_VNC_PORT`
- `OPENCLAW_NOVNC_PORT`
- `OPENCLAW_GATEWAY_PORT`

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
