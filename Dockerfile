FROM nvidia/cuda:13.1.1-cudnn-devel-ubuntu24.04

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

RUN mkdir -p /workspace && chown -R ubuntu:ubuntu /workspace
WORKDIR /workspace

USER ubuntu

RUN git clone https://github.com/Comfy-Org/ComfyUI.git .

RUN python3.12 -m venv /workspace/venv

RUN if [ -f requirements.txt ]; then /workspace/venv/bin/pip install --no-cache-dir -r requirements.txt; fi

RUN if [ -f manager_requirements.txt ]; then /workspace/venv/bin/pip install --no-cache-dir -r manager_requirements.txt; fi

EXPOSE 8188

ENV HF_HOME=/workspace/.cache/hf_download
ENV MODELSCOPE_CACHE=/workspace/.cache/modelscope
ENV U2NET_HOME=/workspace/models/u2net

CMD ["python3", "main.py", "--listen"]
