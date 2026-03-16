# ComfyUI Docker

基于 Docker 的 ComfyUI 部署方案，支持 NVIDIA GPU 加速。

## 功能特性

- 基于 CUDA 13.1.1 + cuDNN + Ubuntu 24.04
- Python 3.12 虚拟环境
- NVIDIA GPU 加速支持
- 数据持久化（模型、自定义节点、工作流等）
- 支持自定义节点扩展

## 快速开始

### 前置要求

- Docker
- Docker Compose
- NVIDIA GPU + NVIDIA Driver
- NVIDIA Container Toolkit

### 构建与运行

```bash
# 构建镜像
docker-compose build

# 启动容器
docker-compose up -d

# 查看日志
docker-compose logs -f
```

访问 http://localhost:8188

## 目录结构

```
.
├── Dockerfile           # Docker 镜像构建文件
├── docker-compose.yml   # 容器编排配置
├── .gitignore          # Git 忽略配置
├── input/              # 输入图片目录
├── output/             # 输出图片目录
├── models/             # 模型文件目录
├── custom_nodes/       # 自定义节点目录
├── user/               # 用户配置目录
└── .cache/             # 缓存目录
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| UID | 运行用户 ID | 1000 |
| GID | 运行用户组 ID | 1000 |

## 管理自定义节点

将自定义节点克隆到 `custom_nodes` 目录：

```bash
cd custom_nodes
git clone <自定义节点仓库>
```

重启容器使新节点生效：

```bash
docker-compose restart
```
