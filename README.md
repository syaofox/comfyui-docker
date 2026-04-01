# ComfyUI Docker

基于 Docker 的 ComfyUI 部署方案，支持 NVIDIA GPU 加速。

## 功能特性

- 基于 `pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime` 官方镜像
- NVIDIA GPU 加速（PyTorch / cuPy / ONNX Runtime GPU / llama.cpp / Flash Attention / SageAttention）
- FFmpeg 预编译版，含 NVENC 硬件编码支持
- 自定义节点 volume 挂载，依赖自动安装
- 触发文件机制控制升级（ComfyUI 本体 + 自定义节点 + 依赖），无需重建容器
- 可选国内镜像加速（apt / pip / GitHub 代理）
- 数据持久化（模型、输入输出、工作流、缓存）

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

### 中国大陆镜像加速

项目提供 `.env.example` 范例文件，复制并修改即可：

```bash
cp .env.example .env
# 编辑 .env，取消注释并填写国内镜像地址
vim .env

docker compose build
docker compose up -d
```

## 目录结构

```
.
├── Dockerfile              # 镜像构建文件
├── docker-compose.yml      # 容器编排配置
├── entrypoint.sh           # 启动脚本
├── .env.example            # 环境变量范例
├── wheel/                  # 预编译 wheel（llama_cpp_python / flash_attn）
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
| `GH_PROXY` | GitHub 加速代理前缀（构建时 + 运行时） | 空（直连） |
| `APT_MIRROR` | apt 包镜像地址（构建时） | 空（官方源） |
| `PIP_MIRROR` | PyPI 镜像地址（构建时） | 空（官方源） |
| `COMFYUI_PATH` | ComfyUI 安装目录 | `/home/comfy/app` |
| `HF_HOME` | HuggingFace 缓存目录 | `/home/comfy/app/.cache/hf_download` |
| `MODELSCOPE_CACHE` | ModelScope 缓存目录 | `/home/comfy/app/.cache/modelscope` |
| `U2NET_HOME` | U2Net 模型目录 | `/home/comfy/app/models/u2net` |

> **注意**: `docker-compose.yml` 中设置了 `shm_size: 8g`，确保容器内有足够共享内存。

## 升级管理

通过触发文件控制 ComfyUI 本体和自定义节点的升级，无需重建容器。

### 触发升级

```bash
touch ./custom_nodes/.update
docker restart comfyui-docker
```

触发后自动依次执行：

1. 升级 ComfyUI 到最新正式 Release（`git ls-remote` 获取最新 tag）
2. 克隆 `DEFAULT_NODES` 中缺失的节点
3. 更新已有节点到最新版本
4. 安装节点的 `requirements.txt` 依赖
5. 删除 `.update` 文件，下次启动不再重复执行

### 默认节点

默认节点定义在 `entrypoint.sh` 的 `DEFAULT_NODES` 数组中。

### 添加节点

编辑 `entrypoint.sh`，在 `DEFAULT_NODES` 数组中追加一行：

```bash
DEFAULT_NODES=(
    ...
    "<作者>/<节点仓库>.git|<目录名>"
)
```

然后触发升级：

```bash
touch ./custom_nodes/.update
docker restart comfyui-docker
```

节点的 `requirements.txt` 依赖会自动安装，同时过滤以下包以避免覆盖镜像自带版本：

`torch` `torchvision` `torchaudio` `cupy-cuda*` `onnxruntime-gpu` `llama_cpp_python`

## 镜像内预装 GPU 包

| 包 | 说明 |
|---|---|
| `torch` / `torchvision` / `torchaudio` | Base image 自带，构建时不会重装 |
| `numpy >=2,<2.6` | 升级 base image 的 numpy 1.x |
| `cupy-cuda13x` | CUDA 加速数组运算 |
| `onnxruntime-gpu` | GPU 版 ONNX 推理 |
| `llama_cpp_python` | 本地 LLM 推理（预编译 wheel） |
| `flash_attn` | Flash Attention 加速（预编译 wheel） |
| `bitsandbytes` | 量化推理 |
| `sageattention` | SageAttention 加速 |
| `PyOpenGL-accelerate` | OpenGL 加速 |

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
