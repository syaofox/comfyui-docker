## Wan Context Windows（`WanContextWindowsManual`）用法详解

这是 ComfyUI 原生的实验性节点（`comfy_extras/nodes_context_windows.py:64`，实现在 `comfy/context_windows.py`），属于 **model/patch/wan** 分类的模型补丁节点。作用是：**把长视频的帧按滑动窗口切分，逐窗口去噪后融合回全序列**，从而让 Wan 这类原生只支持 ~81 帧（约 5 秒）的视频模型生成更长的视频，同时显存占用只按单个窗口计算而非全片。

### 接线方式

```
Load Diffusion Model / LoRA 链 → Wan Context Windows → KSampler (model 输入)
```
节点内部对 model 克隆后写入 `model_options["context_handler"]`，在采样时截获 `calc_cond_batch` 按窗口切 latent 和条件，加权融合回全帧。

### 参数说明

| 参数 | 说明 |
|---|---|
| `context_length` | 窗口长度（**真实帧数**，必须 4n+1，如 81/77/73…）。内部换算为 latent 帧：`((len-1)//4)+1`，默认 81 = 模型原生全窗口 |
| `context_overlap` | 相邻窗口重叠的真实帧数（默认 30），内部 ÷4。典型取窗口长度的 20~30% |
| `context_schedule` | 窗口排布算法：`standard_uniform`（默认，均匀滑窗）、`standard_static`（静态标准）、`looped_uniform`（循环均匀，配 `closed_loop`）、`batched`（整批一次） |
| `context_stride` | 仅 uniform 系算法生效的步幅（advanced，默认 1） |
| `closed_loop` | 仅 looped 算法生效：首尾窗口闭合循环（做无缝循环动画时用，advanced） |
| `fuse_method` | 窗口重叠区融合权重：`pyramid`（默认，重叠区从 0→1 金字塔渐变，过渡最平滑）、`relative`、`flat`（重叠区平权）、`overlap-linear`（线性） |
| `freenoise` | FreeNoise 噪声重排（advanced，默认开启），改善长视频窗口间内容连贯性 |
| `retain_first_frame` | 每个窗口都保留 I2V 首帧（`cond_retain_index_list="0"`）——**I2V 工作流想全程锁定起始参考图时开启** |
| `split_conds_to_windows` | 配合多条件（ConditionCombine）按区域索引把各 conditioning 分配到对应窗口（advanced） |

`dim` 在此节点固定为 2（Wan 时间维），无需手动设置；节点还会装 `prepare_sampling_wrapper`，让显存预估只按窗口 latent 计算，避免长视频被误判 OOM 拒绝执行。

### 典型用法

1. **生成 2 倍长视频（~160 帧）**：`context_length=81`、`overlap=30`、`fuse_method=pyramid`，其余默认即可。
2. **I2V 长视频**：同上 + 开 `retain_first_frame`，防止起始参考图在后续窗口丢失。
3. **无缝循环**：`context_schedule=looped_uniform` + `closed_loop=True`。
4. `context_length` 越小显存越省、但窗口间风格漂移风险越大；`overlap` 过小会出现接缝闪烁。

注意：重叠帧只是加权平均融合，并非真正的运动连续性约束，太长的视频（如 >5 个窗口）仍建议分段 + 首尾帧衔接方案。

---


### 未验证多lora
可以做到，但不是节点直接支持，需要用 ComfyUI 的 hooks 机制 + split_conds_to_windows 组合实现：
直接答案
Context Windows 节点本身没有 per-window LoRA 参数——LoRA 是采样前固定的模型权重补丁，原生机制里整个采样过程权重不变。但 ComfyUI 的两个独立机制叠加后可以实现等效效果：
实现原理
1. split_conds_to_windows=True（comfy/context_windows.py:481）：当有多条 conditioning 时，每个窗口按其中心位置在时间轴上的比例（center_ratio）选取“所属区域”的那条 cond，即每个窗口只消费一条 conditioning。
2. Conditioning hooks：每个 conditioning 可以通过 hooks 节点挂载不同的 weights hook（LoRA hook）。采样时 calc_cond_batch 按 hooks 分组逐组执行（comfy/samplers.py:261），每组先 apply_hooks 换上对应 LoRA 补丁再跑模型（comfy/samplers.py:311）。
3. 两者叠加：窗口 N → 选中区域 N 的 cond → 该 cond 携带的 LoRA hook 被应用 → 该窗口用 LoRA-N 采样。
实际操作要点
- 用 Conditioning Combine（多段 cond 按区域拼接）创建多条 conditioning，每条分别接不同的 LoRA hook（SF LoRA/LoRA Hook 类节点）
- Wan Context Windows 打开 split_conds_to_windows=True（advanced 选项）
- 想更精细控制可叠加 ConditioningSetTimestepRange 或 hook keyframe 做 timestep 级调度
代价与注意
- 性能：每个窗口、每个 timestep 都要准备/应用一次 hook patches（LoRA 重计算），窗口数 × 步数的开销会显著放大
- 边界硬切：pyramid 融合只平滑 latent 重叠区，LoRA 权重在窗口边界是跳变的，风格差异大的 LoRA 会出现明显接缝——相邻窗口风格接近时效果才可接受
- 这是组合 hack 而非官方设计目标，实验性节点 + hooks 组合，建议先小规模验证