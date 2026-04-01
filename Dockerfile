FROM pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime

ARG PUID=1000
ARG PGID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

RUN apt-get update && apt-get install -y \
    sudo \
    git \
    wget \
    curl \
    build-essential \
    cmake \
    pkg-config \
    libopenblas-dev \
    liblapack-dev \
    gfortran \
    libgl1 \
    libgles2 \
    libegl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    # https://github.com/filliptm/ComfyUI_Fill-Nodes.git
    libglut3.12 \
    libglut-dev \
    && rm -rf /var/lib/apt/lists/*

# 安装 FFmpeg (BtbN 预编译版本，带 NVENC 支持)
RUN wget -q https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl-shared.tar.xz && \
    tar -xf ffmpeg-master-latest-linux64-gpl-shared.tar.xz && \
    cp -r ffmpeg-master-latest-linux64-gpl-shared/bin/* /usr/local/bin/ && \
    cp -r ffmpeg-master-latest-linux64-gpl-shared/lib/* /usr/local/lib/ && \
    ldconfig && rm -rf ffmpeg-*

# 验证 NVENC 支持
RUN ffmpeg -hide_banner -encoders 2>/dev/null | grep -q nvenc || (echo "ERROR: NVENC not found in ffmpeg" && exit 1)

# 创建目录结构（root 执行，chown 在 entrypoint 中完成）
RUN mkdir -p /home/comfy/app

WORKDIR /home/comfy/app

# 克隆 ComfyUI
# 使用 git ls-remote 获取最新正式 Release 标签名（不依赖 GitHub API，无限制流问题）
RUN LATEST_TAG=$(git ls-remote --tags https://github.com/Comfy-Org/ComfyUI.git \
        | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1) && \
    if [ -z "$LATEST_TAG" ]; then echo "Error: Could not fetch tag"; exit 1; fi && \
    echo "Cloning Immutable Release: v$LATEST_TAG" && \
    git clone --branch "v$LATEST_TAG" --depth 1 https://github.com/Comfy-Org/ComfyUI.git .

# 移除 PEP 668 限制，允许系统 pip 安装包
RUN rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

# 安装 Python 依赖（root，系统 pip，torch 已在 base image 中，无需重装）
RUN pip install --upgrade pip setuptools wheel

# 升级 numpy（base image 的 numpy 1.x 不兼容 cupy 和 opencv）
RUN pip install --no-cache-dir "numpy>=2,<2.6"

RUN pip install --no-cache-dir cupy-cuda13x

RUN pip install --no-cache-dir onnxruntime-gpu

COPY wheel/llama_cpp_python-0.3.33+cu130.basic-cp312-cp312-linux_x86_64.whl /home/comfy/app/wheel/llama_cpp_python-0.3.33+cu130.basic-cp312-cp312-linux_x86_64.whl

RUN pip install --no-cache-dir /home/comfy/app/wheel/llama_cpp_python-0.3.33+cu130.basic-cp312-cp312-linux_x86_64.whl && \
    rm -f /home/comfy/app/wheel/llama_cpp_python-0.3.33+cu130.basic-cp312-cp312-linux_x86_64.whl

# 生成 constraints 文件，锁定核心包版本（防止传递依赖降级）
RUN python3 -c "import torch, numpy, cupy, onnxruntime; pkgs={'torch':torch.__version__.split('+')[0],'torchvision':__import__('torchvision').__version__,'torchaudio':__import__('torchaudio').__version__,'numpy':numpy.__version__,'cupy-cuda13x':cupy.__version__,'onnxruntime-gpu':onnxruntime.__version__}; [open('/tmp/constraints.txt','a').write(f'{p}=={v}\n') for p,v in pkgs.items()]" && cat /tmp/constraints.txt

RUN if [ -f requirements.txt ]; then \
    grep -v -iE "^(torch|torchvision|torchaudio|numpy)[=~><!]" requirements.txt > /tmp/filtered_requirements.txt && \
    pip install --no-cache-dir -r /tmp/filtered_requirements.txt -c /tmp/constraints.txt; fi

RUN pip install --no-cache-dir bitsandbytes --force-reinstall --no-deps -U

COPY wheel/flash_attn-2.8.3+cu130torch2.10-cp312-cp312-linux_x86_64.whl /home/comfy/app/wheel/flash_attn-2.8.3+cu130torch2.10-cp312-cp312-linux_x86_64.whl

RUN pip install --no-cache-dir /home/comfy/app/wheel/flash_attn-2.8.3+cu130torch2.10-cp312-cp312-linux_x86_64.whl && \
    rm -f /home/comfy/app/wheel/flash_attn-2.8.3+cu130torch2.10-cp312-cp312-linux_x86_64.whl

RUN pip install --no-cache-dir PyOpenGL-accelerate sageattention

# 配置 sudo 免密（entrypoint 中 sudo 切换用户用）
RUN echo "ALL ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/all

COPY entrypoint.sh /entrypoint.sh

EXPOSE 8188

ENV PUID=${PUID}
ENV PGID=${PGID}
ENV HF_HOME=/home/comfy/app/.cache/hf_download
ENV MODELSCOPE_CACHE=/home/comfy/app/.cache/modelscope
ENV U2NET_HOME=/home/comfy/app/models/u2net
ENV COMFYUI_PATH=/home/comfy/app

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
CMD ["python3", "main.py", "--listen"]
