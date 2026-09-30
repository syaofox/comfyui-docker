# AnyAngle Studio「参考图与重建主体不一致」：fp16 中间张量导致的资产名不一致

> 适用场景：T8 AnyAngle Studio 里 3D 重建成功、但点「应用到节点」始终报
> **`参考图与重建主体不一致，请重新重建后应用`**（`storage.py:178`），
> 且**无论重建多少次都不行**。
> 案例时间：2026-09-30，工作流 `user/default/workflows/[test]AnyAngle-Studio-Qwen21.json`。

---

## 一、先看校验在比什么

`storage.py` 的 `save_scene()`（splat 场景）：

```python
if scene["source"]["kind"] == "splat" and source_reference.get("name") != reference.get("name"):
    raise ValueError("参考图与重建主体不一致，请重新重建后应用")
```

资产的「名字」= **PNG 字节的 sha256**（`StudioStore.asset()`，内容寻址）。所以校验要求
「重建时用的原图」和「场景里当前的参考图」**逐字节同一份 PNG**。

## 二、根因：`--fp16-intermediates` + `astype(uint8)` 截断

- 本机 `.env` 里 `COMFYUI_ARGS=--disable-pinned-memory --fp16-intermediates`
  （实验性开关：节点间 IMAGE 张量用 fp16 传输）；
- 节点把张量写回 PNG 时用的是**截断**而非四舍五入：

  ```python
  pixels = np.clip(image[0].cpu().float().numpy() * 255, 0, 255).astype(np.uint8)   # 截断
  ```

- fp16 只有 ~11 位有效精度：`k/255` 转 fp16 再 `*255` 会得到 `k ± 0.12`；
  凡略小于 `k` 的取值，截断后变成 `k-1`。
  实测一张 560×624 的 JPEG：**61% 的像素发生 ±1 偏移**；
- 于是「由张量重新编码出的原图」与「参考图资产文件」sha256 不同 →
  资产名不同（实测 `0fb9f467…` vs `cd88acba…`）→ 校验必然失败。
  作者在 fp32 下开发/测试，所以上游没暴露这个问题。

**关键佐证（可复现）**：把与前端完全相同的重建子图手动 POST 到 `/prompt`
（参考图 = 现有资产 `0fb9f467….png`），输出的 `source.reference` 稳定等于
`cd88acba…` —— 与缓存的旧结果无关，是**每次必然发生**。

### 附：另一条相关的坑（不同症状，别混淆）

本版 ComfyUI 的 `LoadImage` 走 **pyav** 解码（`InputImpl.VideoFromFile`），
而 `StudioStore.asset()` 走 **PIL** 解码。同一张 JPEG 两条路径像素差 ±1 →
**同一张照片上传 vs 连线会得到两个不同资产名**。
所以「肉眼同一张图」并不保证名字相同；修复后两条路径都自洽（见下），
但混用时同名要求仍然成立。

## 三、修复：三处编码改成四舍五入

fp16 的量化误差 < 0.125 LSB，`np.rint` 可精确还原原 uint8 值：

```diff
- pixels = np.clip(x * 255, 0, 255).astype(np.uint8)
+ pixels = np.clip(np.rint(x * 255), 0, 255).astype(np.uint8)
```

共 3 处：`__init__.py`（`reference_image`、`structure_image`）、`reconstruction.py`（`image_asset`）。
补丁文件：`patches/t8-anyangle-fp16-asset-rounding.patch`（路径前缀 `custom_nodes/…`，
由 entrypoint 的补丁机制自动应用，见《ComfyUI核心补丁与BiRefNet-fp16修复.md》第三节）。

### 验证

```bash
# 1) 节点自带单测
docker exec comfyui-docker python3 -m unittest discover \
  -s /home/comfy/app/custom_nodes/Comfyui-Qwen-Image-2.1-MultiAngle-T8/tests -p "test_*.py"

# 2) 端到端：手动提交同一重建子图，检查 source.reference 是否等于参考图资产名
#    （脚本见下，改 ref_name 即可；输出 "与参考图资产一致: ✅" 即修复）
```

实测结果（修复后）：`source.reference = 0fb9f467…png` == 参考图资产名 ✅。

## 四、操作要点（用户视角）

1. 修复后**需要重建一次**：旧的 3D 结果绑定的是旧名字（`cd88acba…`），永远无法通过校验；
2. 顺序：确定参考图（连线读取）→ 重建 → 调机位 → 应用；中途不要换参考图；
3. 若换了参考图（或换了连线的那张照片），必须重新重建后再应用。

## 五、诊断这类问题的方法（临时插桩）

`routes.py` 的 `/anyangle-studio/snapshots` 失败分支加一行打印，即可看到两侧资产名：

```python
except (ValueError, OSError, UnidentifiedImageError) as error:
    scene = (payload or {}).get("scene") or {}
    src = scene.get("source") or {}
    print("[anyangle-diagnose] %r | scene.reference=%r | source.kind=%r | source.reference=%r" % (
        str(error), (scene.get("reference") or {}).get("name"),
        src.get("kind"), (src.get("reference") or {}).get("name")), flush=True)
    return web.json_response({"error": str(error)}, status=400)
```

本次就是靠它 30 秒定位的（改完记得重启容器；诊断完请还原，保持补丁最小）。

## 六、备选方案：去掉 `--fp16-intermediates`

把 `.env` 的 `COMFYUI_ARGS` 改为 `--disable-pinned-memory` 并重启，也能让该问题消失
（fp32 张量往返精确）。代价是该实验性开关带来的省显存/省内存收益一并失去，
且**其它依赖「张量往返字节一致」的逻辑不再受影响**——如果显存够用，这是更省心的选择。
两条路二选一即可，节点补丁与开关兼容（补丁在 fp32 下同样正确）。
