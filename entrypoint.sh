#!/bin/bash
set -e

APP_DIR="/home/comfy/app"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
GH_PROXY="${GH_PROXY:-}"

# GitHub URL 前缀（为空则直连，非空则走代理）
GH="${GH_PROXY:+${GH_PROXY}/}https://github.com/"

# 默认节点列表（URL|目录名）
DEFAULT_NODES=(
    "Comfy-Org/ComfyUI-Manager.git|ComfyUI-Manager"
    # 私有节点列表
    "syaofox/sfnodes.git|sfnodes"
    "syaofox/ComfyUI-llama-cpp_vlm.git|ComfyUI-llama-cpp_vlm"
    "city96/ComfyUI-GGUF.git|ComfyUI-GGUF"
    "syaofox/ComfyUI-ReActor.git|ComfyUI-ReActor"
    # 以下是一些社区流行的节点，用户可根据需要选择性克隆
    "kijai/ComfyUI-KJNodes.git|ComfyUI-KJNodes"
    "LAOGOU-666/Comfyui-Memory_Cleanup.git|Comfyui-Memory_Cleanup"
    "kijai/ComfyUI-MMAudio.git|ComfyUI-MMAudio"
    "yawiii/ComfyUI-Prompt-Assistant.git|ComfyUI-Prompt-Assistant"
    "1038lab/ComfyUI-RMBG.git|ComfyUI-RMBG"
    "numz/ComfyUI-SeedVR2_VideoUpscaler.git|ComfyUI-SeedVR2_VideoUpscaler"
    "Kosinkadink/ComfyUI-VideoHelperSuite.git|ComfyUI-VideoHelperSuite"
    "ClownsharkBatwing/RES4LYF.git|RES4LYF"
    "rgthree/rgthree-comfy.git|rgthree-comfy"
    "chrisgoringe/cg-use-everywhere.git|cg-use-everywhere"
    "cubiq/ComfyUI_essentials.git|ComfyUI_essentials"
    "filliptm/ComfyUI_Fill-Nodes.git|ComfyUI_Fill-Nodes"
    "o-l-l-i/ComfyUI-Olm-DragCrop.git|ComfyUI-Olm-DragCrop"
    "ssitu/ComfyUI_UltimateSDUpscale.git|ComfyUI_UltimateSDUpscale"
    "jtydhr88/ComfyUI-qwenmultiangle.git|ComfyUI-qwenmultiangle"
)

# 创建模型目录
echo "Creating model directories..."
MODEL_DIRECTORIES=(
    checkpoints clip clip_vision configs controlnet
    diffusers diffusion_models embeddings gligen
    hypernetworks loras photomaker style_models
    text_encoders unet upscale_models vae vae_approx
)
for dir in "${MODEL_DIRECTORIES[@]}"; do
    mkdir -p "$APP_DIR/models/$dir"
done

# 确保挂载卷目录存在
mkdir -p "$APP_DIR/input" "$APP_DIR/output" "$APP_DIR/user" "$APP_DIR/.cache"

# 允许 git 操作宿主机挂载的目录（属主与容器内用户不同）
git config --global --add safe.directory '*'

# 升级管理（在宿主机上创建 ./custom_nodes/.update 触发）
UPDATE_FLAG="$APP_DIR/custom_nodes/.update"
if [ -f "$UPDATE_FLAG" ]; then
    echo "Update flag found, starting upgrade..."

    # 1. 升级 ComfyUI 到最新正式 Release
    echo "=== Updating ComfyUI ==="
    LATEST_TAG=$(git ls-remote --tags origin \
        | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1)
    LATEST_TAG="v${LATEST_TAG}"
    if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "v" ]; then
        CURRENT_TAG=$(git -C "$APP_DIR" describe --tags 2>/dev/null || echo "unknown")
        if [ "$CURRENT_TAG" != "$LATEST_TAG" ]; then
            echo "  -> Upgrading ComfyUI: $CURRENT_TAG -> $LATEST_TAG"
            git -C "$APP_DIR" fetch --depth 1 origin "tag" "$LATEST_TAG" \
                && git -C "$APP_DIR" reset --hard "FETCH_HEAD" \
                && echo "  -> ComfyUI upgraded to $LATEST_TAG" \
                || echo "  -> ComfyUI upgrade failed, keeping current version"
            # 重新安装 ComfyUI 的依赖
            if [ -f "$APP_DIR/requirements.txt" ]; then
                echo "  -> Reinstalling ComfyUI requirements..."
                python3 -c "import torch, numpy, cupy, onnxruntime; pkgs={'torch':torch.__version__.split('+')[0],'torchvision':__import__('torchvision').__version__,'torchaudio':__import__('torchaudio').__version__,'numpy':numpy.__version__,'cupy-cuda13x':cupy.__version__,'onnxruntime-gpu':onnxruntime.__version__}; [open('/tmp/constraints.txt','a').write(f'{p}=={v}\n') for p,v in pkgs.items()]"
                grep -v -iE "^(torch|torchvision|torchaudio|numpy)[=~><!]" "$APP_DIR/requirements.txt" > /tmp/filtered_requirements.txt \
                    && pip install --no-cache-dir -r /tmp/filtered_requirements.txt -c /tmp/constraints.txt \
                    || echo "  -> ComfyUI requirements install failed"
            fi
        else
            echo "  -> ComfyUI already at latest ($CURRENT_TAG), skipping"
        fi
    else
        echo "  -> Could not determine latest release tag, skipping ComfyUI update"
    fi

    # 2. 克隆缺失的默认节点
    echo "=== Cloning missing custom nodes ==="
    for entry in "${DEFAULT_NODES[@]}"; do
        repo="${entry%%|*}"
        name="${entry##*|}"
        node_dir="$APP_DIR/custom_nodes/$name"
        if [ ! -d "$node_dir" ]; then
            echo "  -> Cloning: $name"
            git clone --depth 1 "${GH}${repo}" "$node_dir" \
                || echo "  -> Failed to clone $name, skipping"
        fi
    done

    # 3. 更新已有的默认节点
    echo "=== Updating existing custom nodes ==="
    for entry in "${DEFAULT_NODES[@]}"; do
        repo="${entry%%|*}"
        name="${entry##*|}"
        node_dir="$APP_DIR/custom_nodes/$name"
        if [ -d "$node_dir/.git" ]; then
            echo "  -> Updating: $name"
            # 更新 remote URL（应对 GH_PROXY 变化）
            git -C "$node_dir" remote set-url origin "${GH}${repo}" 2>/dev/null || true
            git -C "$node_dir" fetch --depth 1 origin \
                && git -C "$node_dir" reset --hard origin/HEAD \
                || echo "  -> Skipped $name (update failed)"
        fi
    done

    # 4. 安装节点的 pip 依赖
    echo "=== Installing custom node requirements ==="
    python3 -c "import torch, numpy, cupy, onnxruntime; pkgs={'torch':torch.__version__.split('+')[0],'torchvision':__import__('torchvision').__version__,'torchaudio':__import__('torchaudio').__version__,'numpy':numpy.__version__,'cupy-cuda13x':cupy.__version__,'onnxruntime-gpu':onnxruntime.__version__}; [open('/tmp/constraints.txt','a').write(f'{p}=={v}\n') for p,v in pkgs.items()]"
    FILTER_PATTERN="^(torch|torchvision|torchaudio|cupy-cuda|onnxruntime-gpu|llama.cpp.python|llama_cpp_python)[=~><!]"
    for entry in "${DEFAULT_NODES[@]}"; do
        name="${entry##*|}"
        node_dir="$APP_DIR/custom_nodes/$name"
        req_file="$node_dir/requirements.txt"
        if [ -f "$req_file" ]; then
            echo "  -> Installing requirements for: $name"
            grep -v -iE "$FILTER_PATTERN" "$req_file" > /tmp/node_requirements.txt \
                && pip install --no-cache-dir -r /tmp/node_requirements.txt -c /tmp/constraints.txt 2>/dev/null || true
        fi
    done

    rm -f "$UPDATE_FLAG"
    echo "=== Upgrade complete, flag removed ==="
else
    echo "No update flag found, skipping upgrade."
fi

# 创建与宿主 UID:GID 一致的用户
echo "Setting up user (UID=$PUID, GID=$PGID)..."
existing_user=$(getent passwd "$PUID" | cut -d: -f1)
if [ -n "$existing_user" ] && [ "$existing_user" != "root" ]; then
    userdel "$existing_user" 2>/dev/null || true
fi
existing_group=$(getent group "$PGID" | cut -d: -f1)
if [ -n "$existing_group" ] && [ "$existing_group" != "root" ]; then
    groupdel "$existing_group" 2>/dev/null || true
fi

groupadd -g "$PGID" comfy 2>/dev/null || true
useradd -m -u "$PUID" -g comfy -s /bin/bash comfy 2>/dev/null || true

# 修正目录权限（覆盖整个 home 目录，包括 .cache / .triton 等）
chown -R "$PUID:$PGID" "$APP_DIR"
mkdir -p /home/comfy/.cache /home/comfy/.triton
chown -R "$PUID:$PGID" /home/comfy

echo "Starting ComfyUI as user comfy ($PUID:$PGID)..."
exec sudo -u "#$PUID" --preserve-env=HF_HOME,MODELSCOPE_CACHE,U2NET_HOME,COMFYUI_PATH,GH_PROXY,NVIDIA_VISIBLE_DEVICES,NVIDIA_DRIVER_CAPABILITIES \
    -- bash -c "cd $APP_DIR && python3 main.py --listen"
