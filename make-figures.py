"""生成本仓库的四张配图（适合 X/Twitter 与 GitHub README）。

数据全部从 data/*.csv 读取。
关键：不同配置实测到的 prompt token 数会有 ±3 的差异（nonce 长度所致），
所以分组必须按「每个配置内部按 PromptTok 排序后的名次」来分，不能按精确 token 数值分组。
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from pathlib import Path

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False
plt.rcParams["figure.dpi"] = 150
plt.rcParams["savefig.dpi"] = 150
plt.rcParams["savefig.bbox"] = "tight"

ROOT = Path(r"D:\AI\bench-publish")
FIG = ROOT / "figures"
FIG.mkdir(exist_ok=True)
DATA = ROOT / "data"

BLUE, ORANGE, GREEN, GRAY = "#1f77b4", "#ff7f0e", "#2ca02c", "#7f7f7f"


def style(ax, title, xlabel, ylabel, legend=True):
    ax.set_title(title, fontsize=15, fontweight="bold", pad=14)
    ax.set_xlabel(xlabel, fontsize=12)
    ax.set_ylabel(ylabel, fontsize=12)
    ax.grid(True, which="both", alpha=0.25, linestyle="--")
    if legend:
        ax.legend(fontsize=11, framealpha=0.9)


def by_rank(df, label, n=3):
    """该配置的前 n 个测点，按 prompt 长度升序。"""
    return df[df.Label == label].sort_values("PromptTok").head(n).reset_index(drop=True)


# ---------------------------------------------------------------- 图 1
chat = pd.read_csv(DATA / "bench-chat.csv")
chat["Turn"] = chat["Turn"].astype(int)
chat["TtftMs"] = pd.to_numeric(chat["TtftMs"], errors="coerce")

fig, ax = plt.subplots(figsize=(9.5, 5.8))
for key, label, color in [("chat-dual-q40", "q4_0", BLUE),
                          ("chat-dual-int8", "int8", ORANGE),
                          ("chat-dual-k8v4", "k8v4", GREEN)]:
    d = chat[(chat.Label == key) & (chat.TtftMs > 0)].sort_values("Turn")
    ax.plot(d.Turn, d.TtftMs, "o-", color=color, label=label, linewidth=2.3, markersize=9)

ax.set_yscale("log")
ax.set_xticks([1, 2, 3, 4, 5])
ax.set_ylim(300, 400000)
style(ax, "多轮对话：只有第 1 轮需要等", "对话轮次", "首 token 延迟 TTFT (ms，对数刻度)")

q40 = chat[chat.Label == "chat-dual-q40"].sort_values("Turn").reset_index(drop=True)
ax.annotate(f"首轮 {q40.iloc[0].TtftMs/1000:.1f} 秒\n（完整预填充 {int(q40.iloc[0].PromptTokens)} tokens）",
            xy=(1, q40.iloc[0].TtftMs), xytext=(1.9, 220000), fontsize=10.5, color=BLUE,
            ha="center",
            arrowprops=dict(arrowstyle="->", color=BLUE, alpha=0.65, shrinkA=2))
ax.annotate(f"第 4 轮起约 {q40.iloc[3].TtftMs:.0f} ms\n（只处理约 20 个新 token）",
            xy=(4, q40.iloc[3].TtftMs), xytext=(4.62, 1150), fontsize=10.5, color=BLUE,
            ha="center",
            arrowprops=dict(arrowstyle="->", color=BLUE, alpha=0.65, shrinkA=2))
ax.text(0.985, 0.955, "k8v4 第 1 轮引擎崩溃，从第 2 轮开始",
        transform=ax.transAxes, ha="right", va="top", fontsize=9, color=GRAY, style="italic")
fig.savefig(FIG / "fig1-chat-ttft.png")
plt.close(fig)
print("fig1-chat-ttft.png")


# ---------------------------------------------------------------- 图 2
res = pd.read_csv(DATA / "bench-results3.csv")
for c in ("PromptTok", "PrefillMed", "TtftMedMs"):
    res[c] = pd.to_numeric(res[c], errors="coerce")

pairs = [("v3-single-k8v4-131k", "单卡 5060 Ti", GRAY),
         ("v3-dual-k8v4-131k", "双卡 +4060 Laptop", BLUE)]
ranked = {k: by_rank(res, k, 3) for k, _, _ in pairs}

fig, axes = plt.subplots(1, 2, figsize=(13.5, 5.6))
x = range(3)
for ax, metric, ylab, title, logy in [
    (axes[0], "PrefillMed", "预填充速度 (tok/s)", "预填充速度：长 prompt 双卡快 8.4 倍", False),
    (axes[1], "TtftMedMs", "首 token 延迟 (ms)", "首 token 延迟：长 prompt 双卡少等 164 秒", True),
]:
    for i, (key, name, color) in enumerate(pairs):
        vals = ranked[key][metric].tolist()
        ax.bar([xi + i * 0.37 - 0.185 for xi in x], vals, 0.35, label=name, color=color)
        for xi, v in zip(x, vals):
            ax.text(xi + i * 0.37 - 0.185, v * (1.06 if logy else 1.0) + (0 if logy else 8),
                    f"{v:,.0f}", ha="center", fontsize=8.5, color=color)
    ax.set_xticks(list(x))
    ax.set_xticklabels([f"≈{int(v):,}" for v in ranked[pairs[0][0]].PromptTok])
    if logy:
        ax.set_yscale("log")
    style(ax, title, "输入 prompt (tokens)", ylab)

fig.savefig(FIG / "fig2-dual-vs-single.png")
plt.close(fig)
print("fig2-dual-vs-single.png")


# ---------------------------------------------------------------- 图 3
kv_map = [("v3-dual-k8v4-131k", "k8v4", GREEN),
          ("v3-dual-int8-131k", "int8", ORANGE),
          ("v3-dual-q40-131k", "q4_0", BLUE)]
kvrank = {k: by_rank(res, k, 3) for k, _, _ in kv_map}
longq = res[res.Label == "v3-dual-q40-longctx"].sort_values("PromptTok")

fig, ax = plt.subplots(figsize=(10.5, 6))
for i, (key, name, color) in enumerate(kv_map):
    vals = kvrank[key].PrefillMed.tolist()
    ax.bar([xi + i * 0.27 - 0.27 for xi in x], vals, 0.25, label=name, color=color)
    for xi, v in zip(x, vals):
        ax.text(xi + i * 0.27 - 0.27, v + 14, f"{v:.0f}", ha="center", fontsize=9, color=color)

# 把 112K 长上下文作为第 4 组单独加进来（只有 q4_0 / int8 / k8v4 各一次，来自 longctx 与主测试）
extra_vals = []
for key, name, color in [("v3-dual-k8v4-131k", "k8v4", GREEN),
                         ("v3-dual-int8-131k", "int8", ORANGE),
                         ("v3-dual-q40-131k", "q4_0", BLUE)]:
    src = res[(res.Label == ("v3-dual-longctx" if key == "v3-dual-k8v4-131k" else key.replace("-131k", "-longctx")))
              & (res.PromptTok > 100000)]
    extra_vals.append(float(src.PrefillMed.iloc[0]) if len(src) else 0)

ax.set_xticks(list(x) + [3])
ax.set_xticklabels([f"≈{int(v):,}" for v in kvrank[kv_map[0][0]].PromptTok] + ["112,000\n(长上下文)"])
for i, ((key, name, color), v) in enumerate(zip(kv_map, extra_vals)):
    if v:
        ax.bar(3 + i * 0.27 - 0.27, v, 0.25, color=color)
        ax.text(3 + i * 0.27 - 0.27, v + 14, f"{v:.0f}", ha="center", fontsize=9, color=color)

style(ax, "双卡下三种 KV 的预填充速度对比",
      "输入 prompt (tokens)", "预填充速度 (tok/s)")
ax.text(0.5, 1.015, "112K tokens 时三种只差 5%（KV 不再是瓶颈）；差异集中在短/中 prompt",
        transform=ax.transAxes, ha="center", fontsize=10, color=GRAY, style="italic")
fig.savefig(FIG / "fig3-kv-prefill.png")
plt.close(fig)
print("fig3-kv-prefill.png")


# ---------------------------------------------------------------- 图 4
ssd = pd.read_csv(DATA / "bench-ssd.csv")
ssd["ReadMB"] = pd.to_numeric(ssd["ReadMB"], errors="coerce")
ssd["WriteMB"] = pd.to_numeric(ssd["WriteMB"], errors="coerce")
ssd = ssd[ssd.Label != "ssd-k8v4"]          # 剔除已被复核证伪的受干扰样本

fig, axes = plt.subplots(1, 2, figsize=(13.5, 5.4))
names, reads, writes = [], [], []
for lab in ["ssd-q40", "ssd-q40-rerun", "ssd-int8", "ssd-k8v4-rerun"]:
    d = ssd[ssd.Label == lab]
    if len(d):
        names.append(lab.replace("ssd-", "").replace("-rerun", "\n(复核)"))
        reads.append(float(d.ReadMB.iloc[0]))
        writes.append(float(d.WriteMB.iloc[0]))

x = list(range(len(names)))
axes[0].bar([xi - 0.19 for xi in x], reads, 0.36, label="磁盘读（不磨损 SSD）", color=GRAY)
axes[0].bar([xi + 0.19 for xi in x], writes, 0.36, label="磁盘写（影响 SSD 寿命）", color=BLUE)
axes[0].set_yscale("log")
axes[0].set_xticks(x)
axes[0].set_xticklabels(names, fontsize=10)
style(axes[0], "磁盘 I/O：读远多于写", "配置（每 8 个请求）", "数据量 (MB，对数刻度)")

ratio = [r / w if w else 0 for r, w in zip(reads, writes)]
axes[1].barh(x, ratio, color=BLUE, height=0.55)
for yi, v in zip(x, ratio):
    axes[1].text(v + 1.2, yi, f"{v:.0f} : 1", va="center", fontsize=11, fontweight="bold", color=BLUE)
axes[1].set_yticks(x)
axes[1].set_yticklabels(names, fontsize=10)
axes[1].invert_yaxis()
axes[1].set_xlim(0, max(ratio) * 1.25)
style(axes[1], "读 : 写 比例", "倍数", "", legend=False)
axes[1].text(0.985, 0.05, "同一配置两次测量就差 3 倍（37:1 vs 11:1）\n说明 KV 格式之间的差异被噪声淹没",
             transform=axes[1].transAxes, ha="right", fontsize=9.5, color=GRAY, style="italic")

fig.suptitle("KV 量化不磨损 SSD：KV cache 从不落盘，NAND 读取也不消耗寿命",
             fontsize=14, fontweight="bold", y=1.03)
fig.savefig(FIG / "fig4-disk-io.png")
plt.close(fig)
print("fig4-disk-io.png")

print("\n全部完成 ->", FIG)
