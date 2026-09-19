# AGENTS.md - ComfyUI Docker

## 项目概览

基于 Docker 的 ComfyUI 部署（NVIDIA GPU），带模型转换/量化、LoRA 训练等周边工作流。
本仓库是**部署与运维工程**，不是 ComfyUI 源码仓库：宿主机的 `custom_nodes/`、`models/`、
`user/` 等通过 volume 挂进容器，ComfyUI 本体代码只存在于容器内。

- 宿主机仓库：`/mnt/github/comfyui-docker`
- 容器名：`comfyui-docker`（`docker ps` 确认）
- 容器内 ComfyUI 根目录：`/home/comfy/app`（`comfy/`、`main.py`、`custom_nodes/` 等都在这里）
- 访问地址：`http://localhost:8188`
- 硬件环境：15G RAM + RTX 3060 12G（含 61G swap），模型分布在两块盘：
  - 内置盘：`./models`（可写）
  - 第二块盘：`/home/syaofox/comfymodels`（`EXTRA_MODELS_PATH`，容器内 `/home/comfy/app/models-ext`，**只读挂载**）

## 架构

```
comfyui-docker/
├── Dockerfile              # 镜像构建（pytorch cu130 底包 + wheel/ 预编译加速包）
├── docker-compose.yml      # 挂载/环境变量/GPU 预留；shm_size: 4g
├── entrypoint.sh           # 启动脚本：建目录、DEFAULT_NODES 安装/更新、依赖 hash 守卫
├── .env / .env.example     # 用户环境变量（PUID、镜像加速、COMFYUI_ARGS 等）
├── extra_model_paths.yaml  # 第二块盘的模型类别映射（base_path=/home/comfy/app/models-ext）
├── wheel/                  # 预编译 wheel（flash_attn / llama_cpp_python / spas_sage_attn）
├── scripts/                # 构建辅助脚本（如 build_spas_sage_attn_wheel.sh）
├── patches/                # 本地补丁存放目录（当前为空；entrypoint 不会自动应用）
├── custom_nodes/           # 自定义节点（与容器双向同步的 volume）
├── models/                 # 内置模型库（volume；输出/转换默认落在这里）
├── input/ output/ user/    # 输入、输出、工作流与用户配置（volume）
├── .cache/                 # HF/ModelScope/uv/pip 缓存（volume）
└── docs/                   # 经验与专题文档（见文末索引）
```

关键挂载（`docker-compose.yml`）：

| 宿主机 | 容器内 | 模式 |
|---|---|---|
| `./models` | `/home/comfy/app/models` | rw |
| `./custom_nodes` | `/home/comfy/app/custom_nodes` | rw |
| `./input` / `./output` / `./user` / `./.cache` | `/home/comfy/app/{input,output,user,.cache}` | rw |
| `./entrypoint.sh` | `/entrypoint.sh` | ro |
| `./extra_model_paths.yaml` | `/home/comfy/app/extra_model_paths.yaml` | ro |
| `${EXTRA_MODELS_PATH}` | `/home/comfy/app/models-ext` | **ro** |

升级机制：`touch custom_nodes/.update && docker restart comfyui-docker`
（升 ComfyUI 本体 + 节点 + 依赖；`COMFYUI_UPDATE_MODE=tag|latest`；依赖有 hash 守卫，
中断可自愈）。节点列表在 `entrypoint.sh` 的 `DEFAULT_NODES`。

## 硬性操作规则

1. **不要在本机直跑 ComfyUI / 直接 import comfy**。需要 ComfyUI、`comfy_kitchen`、
   `torch` 等运行时环境时，一律 `docker exec -i comfyui-docker python3 ...` 在容器内执行；
   查 ComfyUI 源码也在容器内（宿主仓库没有 `comfy/`）。
2. **改自定义节点 Python 代码后必须 `docker restart comfyui-docker`**（volume 已同步但模块已加载）；
   改节点前端 JS 需浏览器硬刷新（Ctrl+Shift+R）。
3. **`models-ext` 只读**：任何输出/转换/拆分结果都要写到内置 `./models`（或 `./output`），
   不要尝试写 `models-ext`。
4. **不要擅自删除或覆盖用户的模型**。怀疑文件损坏时，改名加 `.corrupt-<sha前8位>` 后缀保留，
   并在报告中说明；删除需用户明确确认。
5. **下载来的模型先校验再使用**：`sha256sum` 对比 HF API `lfs.oid`（见「模型下载与校验」）。
6. 未经用户明确要求，**不执行 git commit / push**；动手前先 `git status` 看基线。
7. **沟通语言用中文**；方案先解释、经确认后再改文件。

## 环境速查

```bash
# 容器状态 / 日志（排查运行时问题首选）
docker ps --format '{{.Names}}\t{{.Status}}'
docker logs --since "2026-09-19T14:50:00" --until "2026-09-19T15:10:00" comfyui-docker 2>&1 | grep -vE "Progress:"

# 容器内执行 Python（注意 -i，heredoc 必须带 -i 才有输出）
docker exec -i comfyui-docker python3 - <<'EOF'
import torch; print(torch.__version__, torch.cuda.get_device_name(0))
EOF

# ComfyUI API（只读查询）
curl -s http://127.0.0.1:8188/queue
curl -s http://127.0.0.1:8188/object_info/UNETLoader
curl -s http://127.0.0.1:8188/history/<prompt_id>

# 语法/格式检查
python3 -m py_compile <file.py>
python3 -m json.tool <file.json> >/dev/null && echo ok
```

模型路径规则（容器内）：
- `get_folder_paths("diffusion_models")` 顺序 = `models/unet` → `models/diffusion_models`
  （两个目录都会扫描），`get_full_path` 按序解析，**同名文件内置优先**。
- `models-ext` 里的模型只读可见；下拉框用相对路径（可含子目录）。

Qwen-Image 配套（已验证）：TE `qwen_2.5_vl_7b_fp8_scaled.safetensors`（type=`qwen_image`），
VAE `qwen_image_vae.safetensors`；Rapid AIO 内嵌 VAE 与标准 VAE 是同一文件。

## 常用工作流

### 模型量化 / 转换（Starnodes Model Converter）
- 完整方法、已打补丁与坑：见 `docs/模型量化与文件校验指南.md`。
- 关键点：`model_type`（层保护）≠ `target_format`（量化格式）；int8_convrot 选普通架构
  profile；Pro 节点有 3 处本地补丁（`custom_nodes/comfyui-starnodes-modelconverter/star_model_converter_pro.py`
  :291/:326/:351），**节点升级会覆盖，需重新应用**（`git diff` 可取回）。
- 转换后必须做逐层反量化验证（误差 ~0.9%）并检查输出 metadata。

### 模型下载与校验
```bash
# 1) 查官方 sha256（HF LFS oid 即 sha256）
curl -s https://huggingface.co/api/models/<repo>/tree/main/<dir>
# 2) 后台多线程下载（setsid 必须，否则 shell 超时会杀掉进程）
setsid nohup aria2c -x 8 -s 8 -k 1M -c --file-allocation=none --retry-wait=5 -m 30 \
  -d <目标目录> -o <文件>.part \
  "https://hf-mirror.com/<repo>/resolve/main/<path>" > /tmp/aria2.log 2>&1 < /dev/null &
# 3) 校验通过后再改名去掉 .part；不通过则重下
sha256sum <文件>.part
```
- 大文件损坏（尺寸正常、sha256 不符）可用 HTTP Range 抽样对比定位，方法见文档。
- 流式拆分 safetensors（零内存）优于节点内置 Splitter（全量载入内存），脚本思路见文档。

### 出图异常排查
按成本从低到高：PNG 内嵌 prompt 还原真实工作流 → A/B 控制变量（已知可用模型对照）→
换加载方式/采样器 → 逐层量化验证 → 文件 sha256 校验。详见文档「三、四节」。

### 大批量任务前
20GB 级模型转换/拆分/加载前，建议先 `docker restart comfyui-docker` 释放常驻内存/显存，
并确认磁盘余量 ≥ 2 倍文件大小（`df -h /mnt/github`）。

## 验证方式（无自动化测试框架）

- 静态：`python3 -m py_compile`、JSON 解析、shell `bash -n`。
- 运行时：`docker logs` 看报错与关键日志；ComfyUI API 的 `/history/<id>` 看 `status`。
- 模型：safetensors header 解析（键/形状/dtype/`_quantization_metadata`）、
  `comfy_kitchen` 逐层反量化对比、ComfyUI 实际加载/出图。
- 工作流改动：用 API `POST /prompt` 提交并轮询 `/history`，出图人工确认。

## 文档索引（docs/）

- `模型量化与文件校验指南.md`：转换器使用、补丁、量化验证、异常排查、下载校验、流式拆分。
- `Wan Context Windows用法详解.md`：长视频滑窗节点用法。
- `lora训练/`：krea2 角色 LoRA 设置、wan2.1 角色 LoRA 训练、ChatGPT 打标。

新增专题经验一律写入 `docs/`（中文、可操作、带命令/脚本与出处），不要只留在会话里。
