# ComfyUI Docker

基于 Docker 的 ComfyUI 部署方案，支持 NVIDIA GPU 加速。

## 功能特性

- 基于 `pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime` 官方镜像
- NVIDIA GPU 加速（PyTorch / cuPy / ONNX Runtime GPU / llama.cpp）
- FFmpeg 预编译版，含 NVENC 硬件编码支持
- 自定义节点 volume 挂载，依赖自动安装
- 启动时可选自动更新自定义节点
- 数据持久化（模型、输入输出、工作流、缓存）
- 提供中国大陆镜像加速版（`Dockerfile.cn`）

## 前置要求

- Docker & Docker Compose
- NVIDIA GPU + 驱动（>= 535）
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)

## 快速开始

```bash
# 构建镜像
docker compose build

# 启动
docker compose up -d

# 查看日志
docker compose logs -f
```

访问 http://localhost:8188

### 中国大陆镜像版

```bash
# 使用国内镜像构建（apt 阿里云 + pip 清华源 + GitHub ghfast.top）
docker compose -f docker-compose.cn.yml build

# 启动
docker compose -f docker-compose.cn.yml up -d
```

构建时可通过 `--build-arg` 覆盖镜像地址：

```bash
docker compose -f docker-compose.cn.yml build \
  --build-arg GH_PROXY=https://your-gh-proxy.com \
  --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn \
  --build-arg PIP_MIRROR=mirrors.cloud.aliyuncs.com/pypi/simple
```

## 目录结构

```
.
├── Dockerfile              # 镜像构建文件（国际源）
├── Dockerfile.cn           # 镜像构建文件（国内镜像加速）
├── docker-compose.yml      # 容器编排配置
├── docker-compose.cn.yml   # 容器编排配置（国内镜像版）
├── entrypoint.sh           # 启动脚本
├── entrypoint.cn.sh        # 启动脚本（国内镜像版）
├── wheel/                  # 预编译 wheel（llama_cpp_python）
├── custom_nodes/           # 自定义节点（volume 挂载）
├── models/                 # 模型文件（volume 挂载）
├── input/                  # 输入文件
├── output/                 # 输出文件
├── user/                   # 用户配置
└── .cache/                 # HuggingFace / ModelScope 缓存
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PUID` | 运行用户 UID | `1000` |
| `PGID` | 运行用户 GID | `1000` |
| `UPDATE_NODES` | 启动时自动 `git pull` 更新自定义节点 | `false` |

### 构建参数（仅 `Dockerfile.cn`）

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `GH_PROXY` | GitHub 加速代理前缀 | `https://ghfast.top` |
| `APT_MIRROR` | apt 包镜像地址 | `mirrors.aliyun.com` |
| `PIP_MIRROR` | PyPI 镜像地址 | `pypi.tuna.tsinghua.edu.cn/simple` |

## 自定义节点管理

默认节点定义在 `entrypoint.sh`（或 `entrypoint.cn.sh`）的 `DEFAULT_NODES` 数组中，格式为 `URL|目录名`。

### 添加节点

编辑 `entrypoint.sh`，在 `DEFAULT_NODES` 数组中追加一行：

```bash
DEFAULT_NODES=(
    ...
    "https://github.com/<作者>/<节点仓库>.git|<目录名>"
)
```

重建镜像后启动，会自动克隆并安装依赖：

```bash
docker compose build && docker compose up -d
```

启动时会自动安装节点的 `requirements.txt` 依赖，同时过滤以下包以避免覆盖镜像自带版本：

`torch` `torchvision` `torchaudio` `cupy-cuda*` `onnxruntime-gpu` `llama_cpp_python`

### 更新节点

```bash
# 方式一：环境变量
UPDATE_NODES=true docker compose up -d

# 方式二：在 .env 中设置
echo "UPDATE_NODES=true" >> .env
docker compose up -d

# 方式三：手动进入容器
docker exec -it comfyui-docker bash
cd /home/comfy/app/custom_nodes/节点名 && git pull
```

自动更新使用 `git pull --ff-only`，有本地修改或冲突时会跳过，不会破坏数据。

## 镜像内预装 GPU 包

| 包 | 说明 |
|---|---|
| `torch` / `torchvision` / `torchaudio` | Base image 自带，构建时不会重装 |
| `numpy >=2,<2.6` | 升级 base image 的 numpy 1.x |
| `cupy-cuda13x` | CUDA 加速数组运算 |
| `onnxruntime-gpu` | GPU 版 ONNX 推理 |
| `llama_cpp_python` | 本地 LLM 推理（预编译 wheel） |
| `bitsandbytes` | 量化推理 |

## 常用命令

```bash
# 构建
docker compose build

# 启动
docker compose up -d

# 停止
docker compose down

# 查看日志
docker compose logs -f

# 重建镜像（代码更新后）
docker compose build --no-cache && docker compose up -d

# 进入容器
docker exec -it comfyui-docker bash
```
