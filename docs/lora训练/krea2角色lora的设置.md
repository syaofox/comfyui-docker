
针对 Krea2 训练角色 LoRA，这三个参数的选择结论很明确：**`noise_scheduler` 必须用 `flowmatch`，`timestep_type` 优先选 `weighted`，而 `timestep_bias` 则建议分阶段策略性调整**。

### 📌 快速选择参考

| 参数 | 推荐设置 | 核心原因 |
| :--- | :--- | :--- |
| **`noise_scheduler`** | **`flowmatch`** | Krea2 基于流匹配（Flow Matching）架构，这是唯一正确的选择。 |
| **`timestep_type`** | **`weighted`** | 社区验证的 Krea2 LoRA 训练配置，能实现更稳定的收敛。 |
| **`timestep_bias`** | **分阶段策略**（见下文） | 先用 `balanced`/`High Noise` 学整体结构，最后用 `Low Noise` 精修细节。 |

### 🔧 各参数选择依据

**`noise_scheduler`：必须为 `flowmatch`**
Krea2 是一个 12B 的单流 MMDiT 模型，其核心训练范式是**流匹配（Flow Matching）**。AI Toolkit 中的 Krea2 实现也明确遵循这一约定（`t=1` 为噪声，`t=0` 为干净图像）。因此，`noise_scheduler` 必须设置为 `"flowmatch"`，这与传统的 `ddpm` 有本质区别。社区分享的 Krea2 训练配置也均证实了这一点。

**`timestep_type`：优先使用 `weighted`**
在 Krea2 的流匹配训练中，每个训练步会从 `(0, 1)` 区间采样一个时间步 `t` 来构建噪声潜变量，不同的采样分布对最终效果影响显著。社区验证的 Krea2 LoRA 训练配方中，`timestep_type` 被设置为 `"weighted"`，这有助于实现更稳定和收敛的训练过程。

**`timestep_bias`：角色 LoRA 的分阶段策略**
这是针对角色 LoRA 训练**最关键的调整点**。社区推荐的分阶段策略如下：
*   **训练前期（如前 2,000 步）**：使用 **`balanced`**（默认）或 **`High Noise`**。这个阶段模型主要学习角色的**整体结构、轮廓和基本身份特征**。
*   **训练后期（如最后 1,000 步）**：切换到 **`Low Noise`**。这个阶段让模型专注于**精修面部细节、纹理、光影等**，从而显著提升角色的最终质感。

### 💡 针对 Krea2 角色 LoRA 的额外提醒
*   **底模选择**：务必在 **Krea-2-Raw** 上进行训练，**不要用 Turbo**。Turbo 是蒸馏后的推理模型，不适合训练；在 Raw 上训练出的 LoRA 可以直接在 Turbo 上使用出图。
*   **Caption 风格**：Krea2 使用 Qwen3-VL 文本编码器，**建议使用自然语言描述**，而非传统的 booru 标签。训练时 caption 超过 512 token 的部分会被截断。
*   **显存参考**：24GB 显存建议使用官方 fp8 底模；32GB 显存可考虑 bf16，但需注意显存余量较小。