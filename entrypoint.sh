#!/bin/bash
set -e

APP_DIR="/home/comfy/app"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# 默认节点列表（URL|目录名）
DEFAULT_NODES=(
    "https://github.com/Comfy-Org/ComfyUI-Manager.git|ComfyUI-Manager"
    "https://github.com/syaofox/sfnodes.git|sfnodes"
    "https://github.com/city96/ComfyUI-GGUF.git|ComfyUI-GGUF"
    "https://github.com/kijai/ComfyUI-KJNodes.git|ComfyUI-KJNodes"
    "https://github.com/syaofox/ComfyUI-llama-cpp_vlm.git|ComfyUI-llama-cpp_vlm"
    "https://github.com/LAOGOU-666/Comfyui-Memory_Cleanup.git|Comfyui-Memory_Cleanup"
    "https://github.com/kijai/ComfyUI-MMAudio.git|ComfyUI-MMAudio"
    "https://github.com/yawiii/ComfyUI-Prompt-Assistant.git|ComfyUI-Prompt-Assistant"
    "https://github.com/syaofox/ComfyUI-ReActor.git|ComfyUI-ReActor"
    "https://github.com/1038lab/ComfyUI-RMBG.git|ComfyUI-RMBG"
    "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git|ComfyUI-SeedVR2_VideoUpscaler"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git|ComfyUI-VideoHelperSuite"
    "https://github.com/ClownsharkBatwing/RES4LYF.git|RES4LYF"
    "https://github.com/rgthree/rgthree-comfy.git|rgthree-comfy"
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

# 克隆缺失的默认节点
echo "Checking default custom nodes..."
for entry in "${DEFAULT_NODES[@]}"; do
    url="${entry%%|*}"
    name="${entry##*|}"
    node_dir="$APP_DIR/custom_nodes/$name"
    if [ ! -d "$node_dir" ]; then
        echo "  -> Cloning: $name"
        git clone --depth 1 "$url" "$node_dir" \
            || echo "  -> Failed to clone $name, skipping"
    fi
done

# 按需更新默认节点（设置 UPDATE_NODES=true 启用）
if [ "$UPDATE_NODES" = "true" ]; then
    echo "Updating custom nodes..."
    for entry in "${DEFAULT_NODES[@]}"; do
        name="${entry##*|}"
        node_dir="$APP_DIR/custom_nodes/$name"
        if [ -d "$node_dir/.git" ]; then
            echo "  -> Updating: $name"
            git -C "$node_dir" pull --ff-only 2>/dev/null \
                || echo "  -> Skipped $name (dirty or conflict)"
        fi
    done
fi

# 安装默认节点的 pip 依赖（root 执行），过滤防止覆盖 base image 版本
echo "Installing requirements for custom nodes..."
FILTER_PATTERN="^(torch|torchvision|torchaudio|cupy-cuda|onnxruntime-gpu|llama.cpp.python|llama_cpp_python)[=~><!]"
for entry in "${DEFAULT_NODES[@]}"; do
    name="${entry##*|}"
    node_dir="$APP_DIR/custom_nodes/$name"
    req_file="$node_dir/requirements.txt"
    if [ -f "$req_file" ]; then
        echo "  -> Installing requirements for: $name"
        grep -v -iE "$FILTER_PATTERN" "$req_file" > /tmp/node_requirements.txt \
            && pip install --no-cache-dir -r /tmp/node_requirements.txt 2>/dev/null || true
    fi
done

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

# 修正目录权限（覆盖 app 目录和用户主目录下的 .cache）
chown -R "$PUID:$PGID" "$APP_DIR"
mkdir -p /home/comfy/.cache
chown -R "$PUID:$PGID" /home/comfy/.cache

echo "Starting ComfyUI as user comfy ($PUID:$PGID)..."
exec sudo -u "#$PUID" --preserve-env=HF_HOME,MODELSCOPE_CACHE,U2NET_HOME,COMFYUI_PATH,NVIDIA_VISIBLE_DEVICES,NVIDIA_DRIVER_CAPABILITIES \
    -- bash -c "cd $APP_DIR && python3 main.py --listen"
