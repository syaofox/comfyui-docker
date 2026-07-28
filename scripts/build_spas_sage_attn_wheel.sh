#!/bin/bash
set -e

WHEEL_DIR="$(cd "$(dirname "$0")/../wheel" && pwd)"
GH_PROXY="${GH_PROXY:-}"

docker run --rm \
  -v "$WHEEL_DIR:/wheel" \
  -e GH_PROXY="$GH_PROXY" \
  pytorch/pytorch:2.10.0-cuda13.0-cudnn9-devel \
  bash -c '
set -ex

rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED
apt-get update && apt-get install -y git
pip install --upgrade pip setuptools wheel

GH="${GH_PROXY:+${GH_PROXY}/}https://github.com/"

git clone --depth 1 "${GH}woct0rdho/SpargeAttn.git" /tmp/spargeattn
cd /tmp/spargeattn

pip install --no-cache-dir einops numpy packaging pybind11 setuptools tqdm

# Patch: include CCCL assert header for CUDA 13.0 compatibility
sed -i "s|NVCC_FLAGS_COMMON = \[|NVCC_FLAGS_COMMON = \[\n    \"-include\", \"cuda/std/__cccl/assert.h\",|" setup.py

TORCH_CUDA_ARCH_LIST="8.0;8.6;8.7;8.9;9.0;12.0" \
  python setup.py bdist_wheel

cp dist/spas_sage_attn-*.whl /wheel/
echo "=== Wheel built successfully ==="
ls -lh /wheel/spas_sage_attn-*.whl
'
