#!/bin/bash
set -e

APP_DIR="/home/comfy/app"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
GH_PROXY="${GH_PROXY:-}"
COMFYUI_UPDATE_MODE="${COMFYUI_UPDATE_MODE:-tag}"

# GitHub URL 前缀（为空则直连，非空则走代理）
GH="${GH_PROXY:+${GH_PROXY}/}https://github.com/"

# 默认节点列表（URL|目录名）
DEFAULT_NODES=(
    "Comfy-Org/ComfyUI-Manager.git|ComfyUI-Manager"
    # 私有节点列表
    "syaofox/sfnodes.git|sfnodes"
    "syaofox/ComfyUI-llama-cpp_vlm.git|ComfyUI-llama-cpp_vlm"    
    # "syaofox/ComfyUI-ReActor.git|ComfyUI-ReActor"
    # 以下是一些社区流行的节点，用户可根据需要选择性克隆
    "city96/ComfyUI-GGUF.git|ComfyUI-GGUF"
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
    "judian17/ComfyUI-PixelSmile-Conditioning-Interpolation.git|ComfyUI-PixelSmile-Conditioning-Interpolation"
    "kohya-ss/ComfyUI-Anima-LLLite.git|ComfyUI-Anima-LLLite"
    "Mirumo0u0/ComfyUI-Cosmos-Reference.git|ComfyUI-Cosmos-Reference"
    "jieg9341-lab/ComfyUI-Krea2-StyleTransfer.git|ComfyUI-Krea2-StyleTransfer"
    "ostris/ComfyUI-Krea2-Ostris-Edit.git|ComfyUI-Krea2-Ostris-Edit"
    "1038lab/ComfyUI-JoyCaption.git|ComfyUI-JoyCaption"
    "lbouaraba/comfyui-krea2edit.git|comfyui-krea2edit"
    "woct0rdho/ComfyUI-RadialAttn.git|ComfyUI-RadialAttn"
    "darksidewalker/ComfyUI-DaSiWa-Nodes.git|ComfyUI-DaSiWa-Nodes"
    "Comfy-Org/Nvidia_RTX_Nodes_ComfyUI.git|Nvidia_RTX_Nodes_ComfyUI"
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

    # 1. 升级 ComfyUI
    echo "=== Updating ComfyUI ==="
    if [ "$COMFYUI_UPDATE_MODE" = "latest" ]; then
        echo "  -> Mode: latest (tracking default branch)"
        CURRENT_SHA=$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
        if git -C "$APP_DIR" fetch --depth 1 origin 2>/dev/null; then
            LATEST_SHA=$(git -C "$APP_DIR" rev-parse FETCH_HEAD 2>/dev/null || echo "unknown")
            if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
                echo "  -> Upgrading ComfyUI: ${CURRENT_SHA:0:8} -> ${LATEST_SHA:0:8}"
                git -C "$APP_DIR" reset --hard FETCH_HEAD \
                    && echo "  -> ComfyUI upgraded to latest commit" \
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
                echo "  -> ComfyUI already at latest ($CURRENT_SHA), skipping"
            fi
        else
            echo "  -> Fetch failed, skipping ComfyUI update"
        fi
    else
        echo "  -> Mode: tag (tracking latest release tag)"
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

    rm -f "$UPDATE_FLAG"
    echo "=== Upgrade complete, flag removed ==="
fi

# 安装节点的 pip 依赖（每次启动都执行，确保新增依赖被安装）
echo "=== Installing custom node requirements ==="
python3 -c "import torch, numpy, cupy, onnxruntime; pkgs={'torch':torch.__version__.split('+')[0],'torchvision':__import__('torchvision').__version__,'torchaudio':__import__('torchaudio').__version__,'numpy':numpy.__version__,'cupy-cuda13x':cupy.__version__,'onnxruntime-gpu':onnxruntime.__version__}; [open('/tmp/constraints.txt','a').write(f'{p}=={v}\n') for p,v in pkgs.items()]"
FILTER_PATTERN="^(torch|torchvision|torchaudio|cupy-cuda|onnxruntime-gpu|llama.cpp.python|llama_cpp_python)[=~><!]"
for entry in "${DEFAULT_NODES[@]}"; do
    name="${entry##*|}"
    node_dir="$APP_DIR/custom_nodes/$name"
    req_file="$node_dir/requirements.txt"
    if [ -f "$req_file" ]; then
        echo "  -> Installing requirements for: $name"
        filtered_req=$(grep -v -iE "$FILTER_PATTERN" "$req_file" || true)
        if [ -n "$filtered_req" ]; then
            echo "$filtered_req" > /tmp/node_requirements.txt
            pip install --no-cache-dir -r /tmp/node_requirements.txt -c /tmp/constraints.txt || true
        fi
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

# 修正目录权限（覆盖整个 home 目录，包括 .cache / .triton 等）
chown -R "$PUID:$PGID" "$APP_DIR"
mkdir -p /home/comfy/.cache /home/comfy/.triton
chown -R "$PUID:$PGID" /home/comfy

# 检测 ComfyUI 的 database migration 是否与当前代码一致
# 不一致时（如切换分支/tag 导致 migration 链变化），自动备份旧库并重建
python3 << 'EOF' 2>/dev/null || true
import os, sqlite3, glob, shutil

db = os.path.join(os.environ['COMFYUI_PATH'], 'user', 'comfyui.db')
if not os.path.isfile(db):
    exit(0)
try:
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute("SELECT version_num FROM alembic_version")
    row = cur.fetchone()
    conn.close()
except Exception:
    exit(0)
if not row:
    exit(0)
rev = row[0]
versions_dir = os.path.join(os.environ['COMFYUI_PATH'], 'alembic_db', 'versions')
found = any(
    f"revision = '{rev}'" in open(f).read() or f'revision = "{rev}"' in open(f).read()
    for f in glob.glob(os.path.join(versions_dir, '*.py'))
)
if found:
    exit(0)
backup = db + f'.migration_error.{int(os.path.getmtime(db))}'
print(f"  -> DB revision '{rev}' not found in migration files, backing up to {backup}")
shutil.copy2(db, backup)
os.remove(db)
for ext in ('.db-wal', '.db-shm'):
    p = db + ext
    if os.path.isfile(p):
        os.remove(p)
print("  -> Old database removed, ComfyUI will create a fresh one")
EOF

echo "Starting ComfyUI as user comfy ($PUID:$PGID)..."
exec sudo -u "#$PUID" --preserve-env=HF_HOME,MODELSCOPE_CACHE,U2NET_HOME,COMFYUI_PATH,GH_PROXY,NVIDIA_VISIBLE_DEVICES,NVIDIA_DRIVER_CAPABILITIES \
    -- bash -c "cd $APP_DIR && python3 main.py --listen"
