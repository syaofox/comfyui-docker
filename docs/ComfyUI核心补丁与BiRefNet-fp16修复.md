# ComfyUI 核心补丁：BiRefNet 背景移除 fp16 报错（attn @ v dtype 不匹配）

> 适用场景：在 12G 显存机器上使用 **AnyAngle Studio 的"去背景 → 三维重建"** 或任何
> 触发核心 `RemoveBackground`（BiRefNet）的流程时，报：
>
> ```
> RuntimeError: expected scalar type Float but found Half
>   File ".../comfy/background_removal/birefnet.py", line 119, in forward
>     x = (attn @ v).transpose(1, 2).reshape(B_, N, C)
>     ~~~~~^~~
> ```
>
> 首次出现：2026-09-30，工作流 `[test]AnyAngle-Studio-Qwen21`（ComfyUI 基线 `fb2315f` / 0.38.0）。

---

## 一、触发链路

AnyAngle Studio 前端（`custom_nodes/Comfyui-Qwen-Image-2.1-MultiAngle-T8/web/editor/reconstruct.mjs`）
在点击重建时会向 `/prompt` 提交一个**子图**，其中前两步就是核心节点：

```
LoadBackgroundRemovalModel(birefnet.safetensors) → RemoveBackground → TripoSplatPreprocessImage → …
```

因此报错虽在"重建"流程里，实际挂的是 **ComfyUI 核心代码**的 dtype 问题。

## 二、根因

`comfy/background_removal/birefnet.py`：

- 模型通过 `comfy.ops.manual_cast` 以 **fp16** 运行（`text_encoder_dtype` 在 CUDA 上返回 fp16）；
- 但 `BasicLayer.forward` 里构造掩码时用的是默认 dtype：

  ```python
  img_mask = torch.zeros((1, Hp, Wp, 1), device=x.device)   # ← fp32
  ...
  attn_mask = attn_mask.masked_fill(...)                    # ← fp32
  ```

- 注意力里 fp16 的 `attn` 与 fp32 的 `mask` 相加 → 整体提升为 fp32 → 随后
  `attn @ v`（v 仍是 fp16）报 `expected scalar type Float but found Half`。

注意同文件第 108 行对 `relative_position_bias` 已经用了 `comfy.ops.cast_to_input(...)`，
所以作者本意就是手动对齐 dtype，掩码这一处是遗漏。

## 三、修复（1 行）

在 `WindowAttention.forward` 中把 mask 显式转换到 `attn` 的 dtype：

```diff
         if mask is not None:
             nW = mask.shape[0]
-            attn = attn.view(B_ // nW, nW, self.num_heads, N, N) + mask.unsqueeze(1).unsqueeze(0)
+            attn = attn.view(B_ // nW, nW, self.num_heads, N, N) + comfy.ops.cast_to_input(mask, attn).unsqueeze(1).unsqueeze(0)
```

- 选在注意力处而不是 `img_mask` 创建处，任何来源的 mask 都被覆盖，且 fp32 全量运行（`--force-fp32`）时行为不变。
- 补丁文件：`patches/comfyui-birefnet-fp16-attn-mask.patch`（基线 `fb2315f`）。

### 应用 / 恢复

```bash
# 应用（ComfyUI 在镜像里，不是 volume；补丁不会自动跟随升级）
docker cp patches/comfyui-birefnet-fp16-attn-mask.patch comfyui-docker:/tmp/
docker exec -w /home/comfy/app comfyui-docker git apply /tmp/comfyui-birefnet-fp16-attn-mask.patch
docker restart comfyui-docker          # 核心 Python 代码需重启生效

# 校验：reverse-check 通过 = 补丁与当前代码完全一致
docker exec -w /home/comfy/app comfyui-docker git apply --reverse --check /tmp/comfyui-birefnet-fp16-attn-mask.patch

# 若升级 ComfyUI 后 git apply 报冲突：先看上游是否已自行修复
docker exec -w /home/comfy/app comfyui-docker git log --oneline -3
docker exec comfyui-docker grep -n "cast_to_input(mask" /home/comfy/app/comfy/background_removal/birefnet.py
```

> ✅ **已实现自动应用（2026-09-30）**：`patches/` 通过 compose 挂载进容器（`/patches:ro`），
> `entrypoint.sh` 每次启动幂等应用（已应用则跳过、上游已改动则告警不阻断），
> Dockerfile 也会 `COPY patches/ /opt/local-patches/` 并在构建时应用一份兜底。
> 因此**镜像重建、容器重建、`touch custom_nodes/.update` 升级 ComfyUI 之后，补丁都会自动补回**。

### 应用 / 恢复

正常情况下**什么都不用做**：把 `*.patch` 放在仓库 `patches/` 顶层，重启容器即可。手动操作见下：

```bash
# 手动应用（不经 entrypoint 时）
docker cp patches/comfyui-birefnet-fp16-attn-mask.patch comfyui-docker:/tmp/
docker exec -w /home/comfy/app comfyui-docker git apply /tmp/comfyui-birefnet-fp16-attn-mask.patch
docker restart comfyui-docker          # 核心 Python 代码需重启生效

# 校验补丁状态（reverse-check 通过 = 当前代码已含该补丁）
docker exec -w /home/comfy/app comfyui-docker git apply --reverse --check /tmp/comfyui-birefnet-fp16-attn-mask.patch

# 查看启动时补丁处理结果
docker logs comfyui-docker 2>&1 | grep -A5 "Applying local core patches"

# 若升级 ComfyUI 后 git apply 报冲突（代码已变化）：先看上游是否自行修复
docker exec comfyui-docker grep -n "cast_to_input(mask" /home/comfy/app/comfy/background_removal/birefnet.py
```

约定与限制：

- 只处理 **`patches/` 顶层**的 `*.patch`（子目录不会自动应用，避免误吃实验性补丁）；
- 补丁需用 `-p1` 语境（`a/comfy/...`、`b/comfy/...`），基线是 ComfyUI `fb2315f`；
- 上下文不匹配时 entrypoint 只告警、不阻断启动——**升级后请顺手 `grep "Applying local core patches" -A5` 看一眼**。

## 四、验证（容器内可复跑）

```bash
docker exec -i comfyui-docker python3 - <<'EOF'
import torch, folder_paths, comfy.utils as u, comfy.bg_removal_model as bm
import comfy.model_management as mm
from comfy_extras.nodes_bg_removal import RemoveBackground

sd = u.load_torch_file(folder_paths.get_full_path("background_removal", "birefnet.safetensors"))
m = bm.load_background_removal_model(sd)
mm.load_model_gpu(m.patcher)
for dtype in (torch.float32, torch.float16):        # fp16 = --fp16-intermediates 场景
    image = torch.rand(1, 640, 640, 3, dtype=dtype)
    with torch.inference_mode():
        out = RemoveBackground.execute(m, image)
    mask = out.result[0] if hasattr(out, "result") else out[0]
    print(dtype, "->", tuple(mask.shape), "峰值显存", round(torch.cuda.max_memory_allocated()/2**30, 2), "GB")
EOF
```

实测（RTX 3060 12G）：两种 dtype 均通过，峰值显存 1.6–2.7 GB。
用真实照片（`docs/images/studio-photo.png`）验证 mask 前景占比 2.3%、范围 [0,1]，非退化解。

**复现时的坑**：手工复现必须包 `torch.inference_mode()` / `torch.no_grad()`，
否则模型参数带梯度、中间激活全部保留，512×512 输入就能吃满 11 GB 显存，
会误判成"模型显存爆炸"（真实执行走推理模式，峰值只有 ~2.7 GB）。

## 五、相关记录

- 首见时间与现场日志：2026-09-30，用户工作流 `[test]AnyAngle-Studio-Qwen21`
  （`user/default/workflows/`），该图本身不含 BiRefNet 节点，报错来自 Studio 前端提交的重建子图。
- 上游若已在新版本修复，可直接删掉本条补丁；判定方法：`grep -n "cast_to_input(mask" .../birefnet.py`。
