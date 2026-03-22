FROM nvidia/cuda:13.1.1-cudnn-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHON_VERSION=3.12 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/workspace/venv \
    PATH="/workspace/venv/bin:$PATH"

RUN apt-get update && apt-get install -y \
    python3.12 \
    python3-pip \
    python3.12-dev \
    python3.12-venv \
    git \
    wget \
    build-essential \
    cmake \
    pkg-config \
    libopenblas-dev \
    liblapack-dev \
    gfortran \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# 安装 FFmpeg (BtbN 预编译版本，带 NVENC 支持)
RUN wget -q https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl-shared.tar.xz && \
    tar -xf ffmpeg-master-latest-linux64-gpl-shared.tar.xz && \
    cp -r ffmpeg-master-latest-linux64-gpl-shared/bin/* /usr/local/bin/ && \
    cp -r ffmpeg-master-latest-linux64-gpl-shared/lib/* /usr/local/lib/ && \
    ldconfig && rm -rf ffmpeg-*

# 验证 NVENC 支持
RUN ffmpeg -hide_banner -encoders 2>/dev/null | grep -q nvenc || (echo "ERROR: NVENC not found in ffmpeg" && exit 1)

RUN mkdir -p /workspace && chown -R ubuntu:ubuntu /workspace
WORKDIR /workspace

USER ubuntu

RUN git clone https://github.com/Comfy-Org/ComfyUI.git .

RUN python3.12 -m venv /workspace/venv

RUN /workspace/venv/bin/pip install --upgrade pip setuptools wheel

RUN /workspace/venv/bin/pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130

COPY wheel/ /workspace/wheel/
COPY user/__manager/snapshots/ /workspace/user/__manager/snapshots/
COPY install_snapshot_pips.py /workspace/install_snapshot_pips.py
RUN /workspace/venv/bin/pip install --no-cache-dir /workspace/wheel/*.whl
RUN /workspace/venv/bin/python /workspace/install_snapshot_pips.py || true

RUN if [ -f requirements.txt ]; then /workspace/venv/bin/pip install --no-cache-dir -r requirements.txt; fi

RUN if [ -f manager_requirements.txt ]; then /workspace/venv/bin/pip install --no-cache-dir -r manager_requirements.txt; fi

RUN /workspace/venv/bin/pip install bitsandbytes --force-reinstall --no-deps -U

EXPOSE 8188

ENV HF_HOME=/workspace/.cache/hf_download
ENV MODELSCOPE_CACHE=/workspace/.cache/modelscope
ENV U2NET_HOME=/workspace/models/u2net

CMD ["python3", "main.py", "--listen"]
