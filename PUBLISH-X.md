# X（Twitter）发布稿：本地大模型基准测试的四个反直觉发现

> 配套完整报告：`bench-report.md`（本地）
> 测试对象：Strata + Qwen3.8-Flash-Next Q2_0，RTX 5060 Ti 16G + RTX 4060 Laptop 8G，32GB DDR5

---

## 排版建议（发之前先看）

| 方案 | 需要 | 适合 |
|---|---|---|
| **单条推文** | 免费账号 | 只发一条最抓人的结论，配一张数据图 |
| **长推文** | **X Premium**（单条上限约 25,000 字符） | 一条发完整个报告 |
| **X Articles** | **X Premium+** | 富文本长文，带标题/图片/嵌入，上限最高（100,000 字符级） |
| **线程（Thread）** | **免费** ✅ | 技术内容首选，逐条讲，传播性最好 |

**你看到别人发的"很大的长文档"，基本都是 Articles 功能**（在 X 里点「Articles / 文章」入口，而不是普通发帖框）。
如果你不想付费，**下面的线程版可以直接免费发**。

---

## 版本 A：单条精华推文（≤280 字符，配图发）

> 给本地大模型做性能测试，我踩了两个坑才发现之前的数字全是错的：
> ① 单次测量噪声高达 8 倍
> ② 重复发同一 prompt 会命中 KV cache，测的根本不是预填充
> 修好方法后，真实对话的 TTFT 是「首轮 137 秒 → 之后 0.4 秒」。

（字符数：约 150，留出空间加话题标签）

---

## 版本 B：线程（免费可发，推荐）⭐

**1/8**
给本地大模型做性能基准，我一共推翻了自己两次。最后得出的结论，可能和你在网上看到的不太一样。🧵

**2/8**
第一个坑：**单次测量完全不可信**。

同样 4801 token 的 prompt，prefill 速度在 **77.8 ~ 625.6 tok/s** 之间摇摆——**8 倍**。我第一版报告里"单卡长 prompt 快 51%"的结论，就是被这个噪声骗出来的。

任何"跑一次看看"的本地模型测试，都别信。

**3/8**
第二个坑：**prompt cache 会污染基准**。

我想靠重复测量取中位数来降噪，结果 server 复用了 KV cache：第 2 次请求的 `prompt_n` 从 **1259 掉到 5**，TTFT 从 6222ms 掉到 64ms。我测的是缓存命中，不是预填充。

修法：每次请求开头插一个**唯一 nonce**，强制完整预填充。之后 CSV 里 `cache_n` 恒为 0。

**4/8**
修好方法后，最有价值的发现是：**真实对话和基准测试完全是两回事**。

之前用 nonce 测出的"长 prompt 要等 100+ 秒"只适用于冷启动。真实多轮对话里（11.5K tokens 上下文）：

- 第 1 轮 TTFT：**137.8 秒**
- 第 2 轮：5.8 秒
- 第 3 轮起：**0.4 秒左右**

**首轮到末轮快了约 330 倍**，因为前面所有内容都命中 KV cache，只有新增的几十个 token 要处理。

**5/8**
另一个反转：**双卡比单卡快 8.4 倍**（长 prompt）。

同样是 17.8K tokens 的输入：
- 单卡 5060 Ti：prefill **95.6 tok/s**，TTFT **186 秒**
- 双卡（+4060 Laptop）：prefill **805.9 tok/s**，TTFT **22 秒**

原因藏在日志里：单卡的 prompt chunk 是 8192，但只有 6322 个 expert cache slots，借出去之后 **99% 的专家只能从磁盘读**，直接卡死 61 秒。双卡虽然单卡 slots 少，但两张卡合计约 8900 个，chunk 还更小。

**6/8**
关于 KV cache 量化（k8v4 / int8 / q4_0），查到一组实测精度数据：

- **int8**（默认）：最精确
- **k8v4**：省 23% 内存，needle 结果与 8-bit 相同，长文档优于 4-bit —— 被低估的折中项
- **q4_0**：省 50% 内存，但**长文档 perplexity +8~12%**（needle 仍通过）

**结论：长文档精读别用 q4_0，日常对话无所谓。**

**7/8**
很多人担心 KV 量化磨损 SSD。实测下来这个担心是错位的：

1. **KV cache 从不落盘**，只在 VRAM/RAM
2. **SSD 磨损来自写入，不来自读取**（NAND 读不消耗 P/E）

8 个 6233-token 请求的实测：磁盘**读 204~1220 MB**，**写只有 5~37 MB**。读:写 ≈ 10~40:1，且三种 KV 的写入差异被噪声完全淹没（同一配置重测能差 6 倍）。

按这个量级，600 TBW 的盘要 **2700 年**才写满。

**8/8**
一个方法论提醒：**磁盘计数器受 Windows 后台活动影响极大**。

我第一次测 k8v4 得到 2153 MB 写入，差点得出"k8v4 磨损 SSD 是 q4_0 的 393 倍"。复核后同配置只有 36.9 MB——**外部干扰**。

教训：**任何单个异常数据点，都要复核再下结论。**

（完整报告和脚本见评论区 👇）

---

## 版本 C：Articles 长文版（需 Premium+）

> 直接投稿件全文：`bench-report.md` 的「一、测试方法演进」+「十七、KV 量化质量」+「十八、SSD 磨损」三节，
> 加上本文件版本 B 的第 4~7 条作为摘要开头。
> Articles 支持 Markdown 风格排版，表格建议改成要点列表（在移动端更易读）。

---

## 英文版（如果面向国际受众）

**Thread (condensed)**

**1/6** I built a local LLM benchmark and had to throw away my own results twice. Here's what survived. 🧵

**2/6** **Single measurements lie.** The same 4801-token prompt gave prefill rates from 77.8 to 625.6 tok/s — an 8× spread.

**3/6** **Prompt cache silently poisons benchmarks.** Repeat the same prompt and `prompt_n` drops from 1259 to 5: you're measuring cache hits, not prefill. Fix: unique nonce per request.

**4/6** **Real chat ≠ cold start.** With 11.5K tokens of context: turn 1 took **137.8s**, but turn 3 onward was **~0.4s**. Only the first turn pays the prefill cost.

**5/6** **Two GPUs beat one by 8.4×** on long prompts: 805.9 vs 95.6 tok/s prefill, 22s vs 186s TTFT. The small card forced 99% of experts to stream from disk.

**6/6** **KV quantization doesn't wear your SSD.** KV lives in VRAM/RAM. Measured read:write ≈ 10–40:1, and all three KV formats wrote 5–37 MB for 8 requests. A 600 TBW drive lasts ~2700 years at that rate.

---

## 版本 D：GitHub + X 的组合打法（推荐）⭐

把完整报告放 GitHub，X 上只发**浓缩线程 + 链接**。这是技术内容的标准做法。

### 关键：链接放在哪里

X 会**降低含外链推文的曝光**。所以位置很重要：

| 做法 | 效果 |
|---|---|
| ❌ 链接放在第 1 条（主帖） | 触达大幅下降，最差的选择 |
| ⚠️ 链接放在线程最后一条 | 可接受，最常见 |
| ✅ **主帖不含链接，链接放在自己回复的第 1 条** | 曝光最好 |
| ✅ 同时在个人简介里放一个 | 配合引导 |

### 推荐流程

1. 先把 GitHub 仓库推上去
2. 发**主帖（不含链接）**——用下面这个模板
3. 依次回复自己的主帖，发第 2~9 条干货
4. **最后一条**放 GitHub 链接 + 一句说明
5. 个人简介里也放一个

### 主帖模板（免费账号，权重 47）

> 我给本地大模型做性能基准，推翻了自己两次。
> 最后活下来的结论，跟网上常见说法不太一样。🧵

### 最后一条模板（放链接）

> 完整报告、原始 CSV、可复现脚本都在 GitHub：
> github.com/你的用户名/仓库名
>
> 最想让人看到的是「方法论：我错在哪」那一节。

### GitHub 链接不会额外吃字数

**X 对任何 URL 都固定按 23 权重计算**，无论链接多长。所以长仓库名不吃亏。

### 为什么这样组合最好

| | 纯线程 | GitHub + 线程 |
|---|---|---|
| 完整性 | 被 140 权重/条卡死，必须大幅删减 | 报告全文无损 |
| 可信度 | 只有结论，无原始数据 | 有 CSV 和脚本，可复现 |
| 传播性 | 依赖内容本身 | 主帖不带链接，不被降权 |
| 可更新 | 发出去改不了 | 修 GitHub 即可，链接不变 |

**唯一注意**：GitHub 仓库里不要放日志文件（可能含完整路径），也不要放模型权重或大文件。