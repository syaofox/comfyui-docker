#!/bin/bash
set -e

APP_DIR="/home/comfy/app"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
GH_PROXY="${GH_PROXY:-}"
COMFYUI_UPDATE_MODE="${COMFYUI_UPDATE_MODE:-tag}"
SKIP_CUSTOM_NODE_REQUIREMENTS="${SKIP_CUSTOM_NODE_REQUIREMENTS:-0}"
FORCE_CUSTOM_NODE_REQUIREMENTS="${FORCE_CUSTOM_NODE_REQUIREMENTS:-0}"
HASH_DIR="/tmp/node_requirements_hashes"
# 从 DEFAULT_NODES 移除节点时的磁盘同步策略：
#   disabled（默认）= 目录改名为 <目录名>.disabled（ComfyUI 原生跳过该后缀），可逆、不丢节点数据
#   delete          = 直接删除目录（重新启用时会重新克隆，节点自己下载的模型/缓存会丢失）
#   off             = 只维护托管台账，不处理磁盘
PRUNE_CUSTOM_NODES="${PRUNE_CUSTOM_NODES:-disabled}"
# 托管台账：记录 entrypoint 克隆/收养过的节点；不在此台账中的目录（手工安装）一律不动
NODE_MANIFEST="$APP_DIR/custom_nodes/.managed_nodes"
NODE_PRUNE_LOG="$APP_DIR/custom_nodes/.pruned.log"

# GitHub URL 前缀（为空则直连，非空则走代理）
GH="${GH_PROXY:+${GH_PROXY}/}https://github.com/"

# 选择安装器：优先 uv pip --system，回退到 pip
get_pip_cmd() {
    if command -v uv >/dev/null 2>&1; then
        echo "uv pip install --system"
    elif python3 -m uv --version >/dev/null 2>&1; then
        echo "python3 -m uv pip install --system"
    else
        echo "pip install --no-cache-dir"
    fi
}

# 统一的 requirements 安装封装（支持 uv/pip，兼容 -c constraints）
install_requirements() {
    local req_file="$1"
    local constraints_file="$2"
    if command -v uv >/dev/null 2>&1; then
        uv pip install --system -r "$req_file" -c "$constraints_file"
    elif python3 -m uv --version >/dev/null 2>&1; then
        python3 -m uv pip install --system -r "$req_file" -c "$constraints_file"
    else
        pip install --no-cache-dir -r "$req_file" -c "$constraints_file"
    fi
}

# 生成 constraints 文件，锁定核心包版本（防止传递依赖降级）
# 注意：transformers 系（transformers / huggingface-hub / tokenizers）必须一起锁。
# transformers 4.x 强制 huggingface-hub<1.0，而 diffusers>=0.40 需要 hub 1.x 的
# get_cached_repo_tree；一旦被节点依赖降级，ComfyUI-SDPose-OOD 等会 import 失败。
# 用 importlib.metadata 读版本，缺失的包自动跳过，不阻断 constraints 生成。
# 与 Dockerfile 的 /usr/local/bin/write_constraints.py 保持同步（构建期用同一套规则）。
write_constraints() {
    python3 - <<'PY' || return 1
import importlib.metadata as md

names = [
    "torch", "torchvision", "torchaudio", "numpy",
    "cupy-cuda13x", "onnxruntime-gpu",
    "transformers", "huggingface-hub", "tokenizers",
    # protobuf：googleapis-common-protos>=6.33.5 需要 6.x+，RMBG 的 <6 是历史遗留
    # 与 Dockerfile 的 /usr/local/bin/write_constraints.py 保持同步
    "protobuf",
]
lines = []
for name in names:
    try:
        lines.append(f"{name}=={md.version(name).split('+')[0]}")
    except md.PackageNotFoundError:
        pass
with open("/tmp/constraints.txt", "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

# 同步 ComfyUI 本体依赖（hash 守卫：requirements/constraints 变化或缓存缺失才安装）
# 只有安装成功才写入 hash，升级过程中断/失败时下次启动会自动重试，避免出现半升级环境
sync_comfy_requirements() {
    [ -f "$APP_DIR/requirements.txt" ] || return 0
    mkdir -p "$HASH_DIR"
    if ! write_constraints; then
        echo "  -> Failed to build constraints, skipping ComfyUI requirements sync"
        return 0
    fi
    grep -v -iE "^(torch|torchvision|torchaudio|numpy)[=~><!]" "$APP_DIR/requirements.txt" > /tmp/filtered_requirements.txt || true
    local new_hash
    new_hash=$(printf "%s\n---CONSTRAINTS---\n%s" "$(cat /tmp/filtered_requirements.txt)" "$(cat /tmp/constraints.txt)" | sha256sum | cut -d' ' -f1)
    local hash_file="$HASH_DIR/comfyui_core.sha256"
    if [[ "$FORCE_CUSTOM_NODE_REQUIREMENTS" != "1" && -f "$hash_file" && "$(cat "$hash_file")" == "$new_hash" ]]; then
        echo "  -> ComfyUI requirements unchanged (hash $new_hash), skipping"
        return 0
    fi
    echo "  -> Installing ComfyUI requirements..."
    if install_requirements /tmp/filtered_requirements.txt /tmp/constraints.txt; then
        echo "$new_hash" > "$hash_file"
        echo "  -> ComfyUI requirements installed (hash $new_hash)"
    else
        echo "  -> ComfyUI requirements install failed (will retry next start, hash not saved)"
    fi
}

# >>> managed-nodes-helpers: 托管台账与节点清理逻辑（begin）
# 只有 entrypoint 克隆/收养过（记录在 $NODE_MANIFEST）的节点才会被自动清理；
# 手工安装或在 ComfyUI-Manager 里安装的节点永远不受影响。
# 本地测试脚本按这两个标记提取函数，标记勿删。

# 读取台账中某节点的记录（输出 name|repo|state 中的 state；无记录输出空）
manifest_state() {
    local name="$1"
    [ -f "$NODE_MANIFEST" ] || return 0
    awk -F'|' -v n="$name" '$1 == n {print $3; exit}' "$NODE_MANIFEST" 2>/dev/null || true
}

# 判断目录的 git origin 是否与 DEFAULT_NODES 里的 repo 匹配
# 兼容 GH_PROXY 前缀（<proxy>/https://github.com/owner/repo.git）与 ssh 形式
node_origin_matches() {
    local dir="$1" repo="$2" origin norm
    [ -d "$dir/.git" ] || return 1
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
    [ -n "$origin" ] || return 1
    norm="${origin/git@github.com:/https://github.com/}"
    if [ -n "$GH" ]; then
        norm="${norm#"${GH%/}/"}"
    fi
    [ "$norm" = "$repo" ] || [[ "$norm" == *"/${repo}" ]]
}

# 处理“已从 DEFAULT_NODES 移除”的托管节点，并重写托管台账（每次启动调用）
# 依赖全局：DEFAULT_NODES / APP_DIR / GH / HASH_DIR / PRUNE_CUSTOM_NODES
#            NODE_MANIFEST / NODE_PRUNE_LOG
sync_custom_nodes() {
    local -A desired_set=() new_state=() new_repo=() handled=()
    local entry repo name state node_dir disabled_dir

    for entry in "${DEFAULT_NODES[@]}"; do
        name="${entry##*|}"
        desired_set["$name"]=1
    done

    case "$PRUNE_CUSTOM_NODES" in
        delete|off|disabled) ;;
        *) echo "  -> WARNING: 未知的 PRUNE_CUSTOM_NODES='$PRUNE_CUSTOM_NODES'，按 disabled 处理"
           PRUNE_CUSTOM_NODES="disabled" ;;
    esac

    # 1) 从 DEFAULT_NODES 移除的托管节点 → 软删除（改名 .disabled）/ 删除
    if [ -f "$NODE_MANIFEST" ] && [ "$PRUNE_CUSTOM_NODES" != "off" ]; then
        while IFS='|' read -r name repo state; do
            [ -n "$name" ] || continue
            case "$name" in \#*) continue ;; esac
            [ -n "${desired_set[$name]:-}" ] && continue
            node_dir="$APP_DIR/custom_nodes/$name"
            disabled_dir="$node_dir.disabled"
            if [ -d "$node_dir" ]; then
                if [ "$PRUNE_CUSTOM_NODES" = "delete" ]; then
                    rm -rf "$node_dir"
                    echo "  -> Deleted: $name (已从 DEFAULT_NODES 移除)"
                    printf '%s delete %s\n' "$(date '+%F %T')" "$name" >> "$NODE_PRUNE_LOG"
                elif [ -d "$disabled_dir" ]; then
                    echo "  -> WARNING: $name 与 $name.disabled 同时存在，请手工处理"
                else
                    mv "$node_dir" "$disabled_dir"
                    handled["$name"]="disabled"
                    echo "  -> Disabled: $name （已改名 $name.disabled，重新加回列表并重启即可恢复）"
                    printf '%s disable %s\n' "$(date '+%F %T')" "$name" >> "$NODE_PRUNE_LOG"
                fi
                rm -f "$HASH_DIR/${name}.sha256"
            elif [ -d "$disabled_dir" ]; then
                if [ "$PRUNE_CUSTOM_NODES" = "delete" ]; then
                    rm -rf "$disabled_dir"
                    echo "  -> Deleted: $name.disabled (残留的软删除目录)"
                    printf '%s delete-disabled %s\n' "$(date '+%F %T')" "$name" >> "$NODE_PRUNE_LOG"
                else
                    echo "  -> Already disabled: $name"
                fi
            else
                echo "  -> Not on disk, dropping record: $name"
            fi
        done < "$NODE_MANIFEST"
    fi

    # 2) 重写台账：DEFAULT_NODES 中磁盘上存在的节点（首次运行自动“收养”）+ 仍在磁盘上的旧记录
    for entry in "${DEFAULT_NODES[@]}"; do
        repo="${entry%%|*}"
        name="${entry##*|}"
        node_dir="$APP_DIR/custom_nodes/$name"
        if [ -d "$node_dir" ]; then
            if [ -z "$(manifest_state "$name")" ] && ! node_origin_matches "$node_dir" "$repo"; then
                echo "  -> WARNING: $name 目录存在但 git origin 与 '$repo' 不匹配，不纳入托管（不会被自动清理）"
                continue
            fi
            new_state["$name"]="active"
            new_repo["$name"]="$repo"
        elif [ -d "$node_dir.disabled" ]; then
            # .disabled 但台账未记录为 entrypoint 软删除 → 视为手工禁用（held），不自动恢复
            if [ "$(manifest_state "$name")" = "disabled" ]; then
                new_state["$name"]="disabled"
            else
                new_state["$name"]="held"
            fi
            new_repo["$name"]="$repo"
        fi
    done
    if [ -f "$NODE_MANIFEST" ]; then
        while IFS='|' read -r name repo state; do
            [ -n "$name" ] || continue
            case "$name" in \#*) continue ;; esac
            [ -n "${desired_set[$name]:-}" ] && continue
            node_dir="$APP_DIR/custom_nodes/$name"
            if [ -n "${handled[$name]:-}" ]; then
                new_state["$name"]="${handled[$name]}"
                new_repo["$name"]="$repo"
            elif [ -d "$node_dir" ]; then
                new_state["$name"]="${state:-active}"
                new_repo["$name"]="$repo"
            elif [ -d "$node_dir.disabled" ]; then
                # 保留 entrypoint 软删除记录（可恢复）；手工禁用只记 held
                if [ "$state" = "disabled" ]; then
                    new_state["$name"]="disabled"
                else
                    new_state["$name"]="held"
                fi
                new_repo["$name"]="$repo"
            fi
        done < "$NODE_MANIFEST"
    fi

    {
        echo "# ComfyUI docker 托管节点台账（entrypoint.sh 自动维护；手工删掉某行 = 解除托管，该目录不再被自动清理）"
        echo "# name|repo|state  state: active=已启用 / disabled=entrypoint 软删除（可自动恢复）/ held=手工禁用（不自动恢复）"
        if [ "${#new_state[@]}" -gt 0 ]; then
            for name in $(printf '%s\n' "${!new_state[@]}" | sort); do
                printf '%s|%s|%s\n' "$name" "${new_repo[$name]}" "${new_state[$name]}"
            done
        fi
    } > "$NODE_MANIFEST.tmp"
    mv "$NODE_MANIFEST.tmp" "$NODE_MANIFEST"
    echo "  -> Manifest updated: $NODE_MANIFEST (${#new_state[@]} managed nodes)"
}
# <<< managed-nodes-helpers: 托管台账与节点清理逻辑（end）

# 默认节点列表（URL|目录名）
DEFAULT_NODES=(
    "Comfy-Org/ComfyUI-Manager.git|ComfyUI-Manager"
    # 私有节点列表
    "syaofox/sfnodes.git|sfnodes"
    "syaofox/ComfyUI-llama-cpp_vlm.git|ComfyUI-llama-cpp_vlm"
    "syaofox/ComfyUI-RMBG.git|ComfyUI-RMBG"
    "syaofox/ComfyUI-YCNodes_Toolkit.git|ComfyUI-YCNodes_Toolkit"
    # "syaofox/ComfyUI-ReActor.git|ComfyUI-ReActor"
    # 以下是一些社区流行的节点，用户可根据需要选择性克隆
    "1038lab/ComfyUI-QwenVL.git|ComfyUI-QwenVL"
    # "1038lab/ComfyUI-RMBG.git|ComfyUI-RMBG"
    "chrisgoringe/cg-use-everywhere.git|cg-use-everywhere"
    "Auryg/Krea-2-Two-Stage-Sampler.git|Krea-2-Two-Stage-Sampler"
    "capitan01R/ComfyUI-Krea2T-Enhancer.git|ComfyUI-Krea2T-Enhancer"
    "CCpt5/ComfyUI-BerniniStudio.git|ComfyUI-BerniniStudio"
    "city96/ComfyUI-GGUF.git|ComfyUI-GGUF"
    "ClownsharkBatwing/RES4LYF.git|RES4LYF"
    "Comfy-Org/Nvidia_RTX_Nodes_ComfyUI.git|Nvidia_RTX_Nodes_ComfyUI"
    "ethanfel/ComfyUI-Krea2TextEncoder.git|ComfyUI-Krea2TextEncoder"
    "facok/comfyui-krea2-controlnet.git|comfyui-krea2-controlnet"
    "Fannovel16/comfyui_controlnet_aux.git|comfyui_controlnet_aux"
    "Fannovel16/ComfyUI-Frame-Interpolation.git|ComfyUI-Frame-Interpolation"
    "jieg9341-lab/ComfyUI-Krea2-StyleTransfer.git|ComfyUI-Krea2-StyleTransfer"
    "jtydhr88/ComfyUI-qwenmultiangle.git|ComfyUI-qwenmultiangle"
    "judian17/ComfyUI-PixelSmile-Conditioning-Interpolation.git|ComfyUI-PixelSmile-Conditioning-Interpolation"
    "kijai/ComfyUI-KJNodes.git|ComfyUI-KJNodes"
    "kijai/ComfyUI-MMAudio.git|ComfyUI-MMAudio"
    "kohya-ss/ComfyUI-Anima-LLLite.git|ComfyUI-Anima-LLLite"
    "Kosinkadink/ComfyUI-VideoHelperSuite.git|ComfyUI-VideoHelperSuite"
    "lbouaraba/comfyui-krea2edit.git|comfyui-krea2edit"
    "lookuters22/MAGICMATCH.git|MAGICMATCH"
    "ostris/ComfyUI-Krea2-Ostris-Edit.git|ComfyUI-Krea2-Ostris-Edit"    
    "rgthree/rgthree-comfy.git|rgthree-comfy"
    "smthemex/ComfyUI_UniBlockSwap.git|ComfyUI_UniBlockSwap"
    "ssitu/ComfyUI_UltimateSDUpscale.git|ComfyUI_UltimateSDUpscale"
    "woct0rdho/ComfyUI-RadialAttn.git|ComfyUI-RadialAttn"
    "yawiii/ComfyUI-Prompt-Assistant.git|ComfyUI-Prompt-Assistant"
    "KonokoAz/ComfyUI-Krea2-Reference.git|ComfyUI-Krea2-Reference"
    "lrzjason/ComfyUI-EditUtils.git|ComfyUI-EditUtils"
    "judian17/ComfyUI-SDPose-OOD.git|ComfyUI-SDPose-OOD"
    "judian17/ComfyUI_YOLO_For_Multi_SDPose_Detection.git|ComfyUI_YOLO_For_Multi_SDPose_Detection"
    "erosDiffusion/ComfyUI-EulerDiscreteScheduler.git|ComfyUI-EulerDiscreteScheduler"
    # "https://gitlab.com/pixaroma/comfyui-pixaroma.git|comfyui-pixaroma"
    # "zeus-onl/RegioCraft.git|RegioCraft"
    "capitan01R/ComfyUI-Flux2Klein-Enhancer.git|ComfyUI-Flux2Klein-Enhancer"
    "alexw5702-afk/krea2-anypaint.git|krea2-anypaint"
    # "princepainter/ComfyUI-PainterI2V.git|ComfyUI-PainterI2V"


    # "darksidewalker/ComfyUI-DaSiWa-Nodes.git|ComfyUI-DaSiWa-Nodes"
    # "1038lab/ComfyUI-JoyCaption.git|ComfyUI-JoyCaption"
    # "Mirumo0u0/ComfyUI-Cosmos-Reference.git|ComfyUI-Cosmos-Reference"
    
    # "cubiq/ComfyUI_essentials.git|ComfyUI_essentials"
    "filliptm/ComfyUI_Fill-Nodes.git|ComfyUI_Fill-Nodes"
    # "o-l-l-i/ComfyUI-Olm-DragCrop.git|ComfyUI-Olm-DragCrop"
    # "numz/ComfyUI-SeedVR2_VideoUpscaler.git|ComfyUI-SeedVR2_VideoUpscaler"
    # "LAOGOU-666/Comfyui-Memory_Cleanup.git|Comfyui-Memory_Cleanup"
    # "yolain/ComfyUI-Easy-Use.git|ComfyUI-Easy-Use"
    "chflame163/ComfyUI_LayerStyle.git|ComfyUI_LayerStyle"
    # "Suzie1/ComfyUI_Comfyroll_CustomNodes.git|ComfyUI_Comfyroll_CustomNodes"
    # "ltdrdata/was-node-suite-comfyui.git|was-node-suite-comfyui"
    # "LAOGOU-666/Comfyui_LG_Tools.git|Comfyui_LG_Tools"
    # "Q0809/ComfyUI-Krea2-Accel.git|ComfyUI-Krea2-Accel"
    "daniabib/ComfyUI_ProPainter_Nodes.git|ComfyUI_ProPainter_Nodes"
    # 语义识别遮罩
    "9nate-drake/Comfyui-SecNodes.git|Comfyui-SecNodes"
    # "nkxx188/ComfyUI-SCAIL2-Easy.git|ComfyUI-SCAIL2-Easy"
    "WhatDreamsCost/WhatDreamsCost-ComfyUI.git|WhatDreamsCost-ComfyUI"
    # "TTPlanetPig/comfyui_scail2_multi_cond.git|comfyui_scail2_multi_cond"
    # "FuouM/ComfyUI-MatAnyone.git|ComfyUI-MatAnyone"
    "Starnodes2024/comfyui-starnodes-modelconverter.git|comfyui-starnodes-modelconverter"
    # "DocWorkBox/ComfyUI-AuK_Doc.git|ComfyUI-AuK_Doc"
    "T8mars/Comfyui-Qwen-Image-2.1-MultiAngle-T8.git|Comfyui-Qwen-Image-2.1-MultiAngle-T8"
)

# 创建模型目录
echo "Creating model directories..."
MODEL_DIRECTORIES=(
    checkpoints clip clip_vision configs controlnet
    diffusers diffusion_models embeddings frame_interpolation gligen
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
        git -C "$APP_DIR" remote set-head origin -a 2>/dev/null || true
        if git -C "$APP_DIR" fetch --depth 1 origin master 2>/dev/null; then
            LATEST_SHA=$(git -C "$APP_DIR" rev-parse FETCH_HEAD 2>/dev/null || echo "unknown")
            if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
                echo "  -> Upgrading ComfyUI: ${CURRENT_SHA:0:8} -> ${LATEST_SHA:0:8}"
                git -C "$APP_DIR" reset --hard FETCH_HEAD \
                    && echo "  -> ComfyUI upgraded to latest commit" \
                    || echo "  -> ComfyUI upgrade failed, keeping current version"
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
            else
                echo "  -> ComfyUI already at latest ($CURRENT_TAG), skipping"
            fi
        else
            echo "  -> Could not determine latest release tag, skipping ComfyUI update"
        fi
    fi

    # 2. 更新已有的默认节点（成功后清除 hash，强制下阶段重装）
    echo "=== Updating existing custom nodes ==="
    for entry in "${DEFAULT_NODES[@]}"; do
        repo="${entry%%|*}"
        name="${entry##*|}"
        node_dir="$APP_DIR/custom_nodes/$name"
        if [ -d "$node_dir/.git" ]; then
            echo "  -> Updating: $name"
            # 更新 remote URL（应对 GH_PROXY 变化；完整 URL 直接使用，不拼 GH 前缀）
            case "$repo" in
                http://*|https://*) repo_url="$repo" ;;
                *) repo_url="${GH}${repo}" ;;
            esac
            git -C "$node_dir" remote set-url origin "$repo_url" 2>/dev/null || true
            if git -C "$node_dir" fetch --depth 1 origin && git -C "$node_dir" reset --hard origin/HEAD; then
                echo "  -> Updated $name, clearing requirements hash"
                rm -f "$HASH_DIR/${name}.sha256"
            else
                echo "  -> Skipped $name (update failed)"
            fi
        fi
    done

    rm -f "$UPDATE_FLAG"
    echo "=== Upgrade complete, flag removed ==="
fi

# 应用本地核心补丁（幂等）：ComfyUI 在镜像层，升级/重建都会清掉补丁，这里每次启动自动补回
# 补丁来源：/patches（compose 挂载）优先，其次镜像内置 /opt/local-patches
# 已应用（reverse-check 通过）→ 跳过；上下文不匹配（上游已改动/已修复）→ 告警但不阻断启动
echo "=== Applying local core patches ==="
PATCH_DIR="/patches"
[ -d "$PATCH_DIR" ] || PATCH_DIR="/opt/local-patches"
if [ -d "$PATCH_DIR" ]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [ -f "$patch" ] || continue
        patch_name=$(basename "$patch")
        if git -C "$APP_DIR" apply --reverse --check "$patch" 2>/dev/null; then
            echo "  -> $patch_name: already applied, skipping"
        elif git -C "$APP_DIR" apply --check "$patch" 2>/dev/null; then
            if git -C "$APP_DIR" apply "$patch" 2>/dev/null; then
                echo "  -> $patch_name: applied"
            else
                echo "  -> $patch_name: WARNING apply failed, continuing"
            fi
        else
            echo "  -> $patch_name: WARNING cannot apply (代码已变化，可能上游已修复；请人工确认)"
        fi
    done
else
    echo "  -> No patch directory found, skipping"
fi

# 同步 ComfyUI 本体依赖（每次启动执行；hash 不变时秒过，可自愈被打断/失败的升级安装）
echo "=== Syncing ComfyUI requirements ==="
sync_comfy_requirements

# 克隆缺失的默认节点；恢复本脚本软删除（.disabled）的节点
# （每次启动都检查，确保新增节点被克隆、被注释后又取消注释的节点被找回）
echo "=== Cloning missing custom nodes ==="
for entry in "${DEFAULT_NODES[@]}"; do
    repo="${entry%%|*}"
    name="${entry##*|}"
    node_dir="$APP_DIR/custom_nodes/$name"
    if [ ! -d "$node_dir" ] && [ -d "$node_dir.disabled" ]; then
        if [ "$(manifest_state "$name")" = "disabled" ]; then
            mv "$node_dir.disabled" "$node_dir"
            echo "  -> Restored: $name (从 $name.disabled 恢复，未重新下载)"
        else
            echo "  -> Skipping $name: 检测到手工禁用的 $name.disabled（如需启用请手工改名回来）"
            continue
        fi
    fi
    if [ ! -d "$node_dir" ]; then
        echo "  -> Cloning: $name"
        case "$repo" in
            http://*|https://*) repo_url="$repo" ;;
            *) repo_url="${GH}${repo}" ;;
        esac
        git clone --depth 1 "$repo_url" "$node_dir" \
            || echo "  -> Failed to clone $name, skipping"
    fi
done

# 同步托管台账：从 DEFAULT_NODES 移除的节点 → 软删除（.disabled）/ 删除
# 首次运行会“收养” DEFAULT_NODES 中已存在且 origin 匹配的目录；手工目录不受影响
echo "=== Syncing managed custom nodes ==="
sync_custom_nodes

# 安装节点的 pip 依赖（hash 守卫 + uv pip，/tmp 方案：重启跳过，更新或变更才重装）
if [[ "$SKIP_CUSTOM_NODE_REQUIREMENTS" == "1" || "$SKIP_CUSTOM_NODE_REQUIREMENTS" == "true" || "$SKIP_CUSTOM_NODE_REQUIREMENTS" == "yes" ]]; then
    echo "=== Skipping custom node requirements (SKIP_CUSTOM_NODE_REQUIREMENTS=$SKIP_CUSTOM_NODE_REQUIREMENTS) ==="
else
    echo "=== Installing custom node requirements ==="
    mkdir -p "$HASH_DIR"
    write_constraints
    # 核心托管包：从节点 requirements 中剔除，统一由 constraints 锁定版本
    # （transformers 系被剔除后，AuK_Doc 的 transformers<5 不会再把环境降级到 4.x）
    # 包名后必须是行尾/空白/版本符等非包名字符，避免误伤 transformers_stream_generator 之类的包
    # 与 Dockerfile 构建期 FILTER_PATTERN 保持同步
    # onnxruntime(-gpu): 节点里的裸 onnxruntime 与 onnxruntime-gpu 都剔除，
    # 统一由 constraints 锁定的 onnxruntime-gpu 提供模块，避免 CPU 版覆盖 GPU 版 .so
    # protobuf: 节点里的 protobuf pin（如 RMBG 的 <6）剔除，避免降级打挂
    # googleapis-common-protos（Fill-Nodes 的 google-cloud-storage 依赖）
    FILTER_PATTERN="^[[:space:]]*(torch|torchvision|torchaudio|transformers|tokenizers|huggingface[-_]hub|cupy-cuda[0-9]*|onnxruntime(-gpu)?|protobuf|llama[._]cpp[._]python)([^A-Za-z0-9_.-]|$)"
    PIP_CMD_STR=$(get_pip_cmd)
    echo "  -> Using installer: $PIP_CMD_STR"
    for entry in "${DEFAULT_NODES[@]}"; do
        name="${entry##*|}"
        node_dir="$APP_DIR/custom_nodes/$name"
        req_file="$node_dir/requirements.txt"
        [ -f "$req_file" ] || req_file="$node_dir/requirements-no-cupy.txt"
        [ -f "$req_file" ] || continue
        filtered_req=$(grep -v -iE "$FILTER_PATTERN" "$req_file" || true)
        [ -n "$filtered_req" ] || continue
        # hash 包含过滤后的 requirements + constraints，避免 torch/numpy 升级后误跳过
        new_hash=$(printf "%s\n---CONSTRAINTS---\n%s" "$filtered_req" "$(cat /tmp/constraints.txt)" | sha256sum | cut -d' ' -f1)
        hash_file="$HASH_DIR/${name}.sha256"
        if [[ "$FORCE_CUSTOM_NODE_REQUIREMENTS" != "1" && -f "$hash_file" && "$(cat "$hash_file")" == "$new_hash" ]]; then
            echo "  -> Skipping $name (requirements unchanged, hash $new_hash)"
            continue
        fi
        echo "  -> Installing requirements for: $name"
        echo "$filtered_req" > /tmp/node_requirements.txt
        if install_requirements /tmp/node_requirements.txt /tmp/constraints.txt; then
            echo "$new_hash" > "$hash_file"
            echo "  -> Installed $name (hash $new_hash)"
        else
            echo "  -> Failed to install $name (will retry next start, hash not saved)"
        fi
    done
fi

# onnxruntime 健康检查：GPU 版与 CPU 版共用 module 名，后装者覆盖文件。
# 传递依赖（如 insightface）可能又装回 CPU 版，导致 CUDA EP 消失（推理退 CPU）。
if ! python3 -c "import onnxruntime as o, sys; sys.exit(0 if 'CUDAExecutionProvider' in o.get_available_providers() else 1)" 2>/dev/null; then
    echo "  -> WARNING: onnxruntime 缺少 CUDAExecutionProvider（可能被 CPU 版覆盖）"
    echo "     修复：docker exec -i comfyui-docker uv pip install --system onnxruntime-gpu"
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
# 跳过只读挂载（额外模型路径 / extra_model_paths.yaml），否则 chown 在只读文件系统上报错
mkdir -p /home/comfy/.cache /home/comfy/.triton
find /home/comfy \
    -path "$APP_DIR/models-ext" -prune -o \
    -path "$APP_DIR/extra_model_paths.yaml" -prune -o \
    -exec chown "$PUID:$PGID" {} + 2>/dev/null || true

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
if [ -n "${COMFYUI_ARGS:-}" ]; then
    echo "  -> Extra ComfyUI args: $COMFYUI_ARGS"
fi
exec sudo -u "#$PUID" --preserve-env=HF_ENDPOINT,HF_HOME,MODELSCOPE_CACHE,U2NET_HOME,COMFYUI_PATH,GH_PROXY,NVIDIA_VISIBLE_DEVICES,NVIDIA_DRIVER_CAPABILITIES \
    -- bash -c "cd $APP_DIR && python3 main.py --listen ${COMFYUI_ARGS:-}"
