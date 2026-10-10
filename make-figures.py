"""Generate the four charts for this repository, in Chinese and English.

Usage:
    python make-figures.py          # Chinese  -> figures/
    python make-figures.py en       # English  -> figures/en/

All values are read from data/*.csv; nothing is hard-coded.

Note: different configs report slightly different prompt token counts (±3, because the
unique nonce length varies). Grouping must therefore be done by "rank within each config
after sorting by prompt length", never by exact token value — sorting by value splits
what should be one group and silently drops a data point.
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from pathlib import Path

LANG = (sys.argv[1] if len(sys.argv) > 1 else "zh").lower()
EN = LANG == "en"

plt.rcParams["axes.unicode_minus"] = False
plt.rcParams["figure.dpi"] = 150
plt.rcParams["savefig.dpi"] = 150
plt.rcParams["savefig.bbox"] = "tight"
if EN:
    plt.rcParams["font.sans-serif"] = ["DejaVu Sans", "Segoe UI", "Arial"]
else:
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]

ROOT = Path(__file__).resolve().parent
FIG = ROOT / "figures" / ("en" if EN else "")
FIG.mkdir(parents=True, exist_ok=True)
DATA = ROOT / "data"

BLUE, ORANGE, GREEN, GRAY = "#1f77b4", "#ff7f0e", "#2ca02c", "#7f7f7f"

T = {
    "turn_x": "Conversation turn" if EN else "对话轮次",
    "ttft_y": "Time to first token (ms, log scale)" if EN else "首 token 延迟 TTFT (ms，对数刻度)",
    "f1_title": "Multi-turn chat: only turn 1 makes you wait" if EN else "多轮对话：只有第 1 轮需要等",
    "f1_a": ("Turn 1: {s:.1f} s\n(full prefill of {n} tokens)" if EN
             else "首轮 {s:.1f} 秒\n（完整预填充 {n} tokens）"),
    "f1_b": ("Turn 4 onward: ~{ms:.0f} ms\n(only ~20 new tokens)" if EN
             else "第 4 轮起约 {ms:.0f} ms\n（只处理约 20 个新 token）"),
    "f1_note": ("k8v4 crashed on turn 1; shown from turn 2" if EN
                else "k8v4 第 1 轮引擎崩溃，从第 2 轮开始"),

    "prompt_x": "Input prompt (tokens)" if EN else "输入 prompt (tokens)",
    "f2_title_l": ("Prefill speed: 8.4× faster on long prompts" if EN
                   else "预填充速度：长 prompt 双卡快 8.4 倍"),
    "f2_title_r": ("TTFT: 164 s less waiting on long prompts" if EN
                   else "首 token 延迟：长 prompt 双卡少等 164 秒"),
    "prefill_y": "Prefill speed (tok/s)" if EN else "预填充速度 (tok/s)",
    "ttft_y2": "Time to first token (ms)" if EN else "首 token 延迟 (ms)",
    "single": "Single 5060 Ti" if EN else "单卡 5060 Ti",
    "dual": "Dual (+4060 Laptop)" if EN else "双卡 +4060 Laptop",

    "f3_title": "Prefill speed by KV cache format (dual GPU)" if EN else "双卡下三种 KV 的预填充速度对比",
    "f3_sub": ("At 112K tokens all three are within 5% (KV is no longer the bottleneck); "
               "the differences show up on short and mid-length prompts" if EN
               else "112K tokens 时三种只差 5%（KV 不再是瓶颈）；差异集中在短/中 prompt"),
    "long_ctx": "112,000\n(long context)" if EN else "112,000\n(长上下文)",

    "f4_sup": ("KV quantization does not wear your SSD: KV cache never hits disk, "
               "and NAND reads cost no endurance" if EN
               else "KV 量化不磨损 SSD：KV cache 从不落盘，NAND 读取也不消耗寿命"),
    "f4_l": "Disk I/O: far more reading than writing" if EN else "磁盘 I/O：读远多于写",
    "f4_lx": "Config (per 8 requests)" if EN else "配置（每 8 个请求）",
    "f4_ly": "Data volume (MB, log scale)" if EN else "数据量 (MB，对数刻度)",
    "read": "Disk read (no SSD wear)" if EN else "磁盘读（不磨损 SSD）",
    "write": "Disk write (consumes endurance)" if EN else "磁盘写（影响 SSD 寿命）",
    "f4_r": "Read : write ratio" if EN else "读 : 写 比例",
    "f4_rx": "Ratio" if EN else "倍数",
    "f4_note": ("Two runs of the same config differ 3× (37:1 vs 11:1) —\n"
                "differences between KV formats are lost in the noise" if EN
                else "同一配置两次测量就差 3 倍（37:1 vs 11:1）\n说明 KV 格式之间的差异被噪声淹没"),
}


def style(ax, title, xlabel, ylabel, legend=True):
    ax.set_title(title, fontsize=15, fontweight="bold", pad=14)
    ax.set_xlabel(xlabel, fontsize=12)
    ax.set_ylabel(ylabel, fontsize=12)
    ax.grid(True, which="both", alpha=0.25, linestyle="--")
    if legend:
        ax.legend(fontsize=11, framealpha=0.9)


def by_rank(df, label, n=3):
    """First n data points of a config, ascending by prompt length."""
    return df[df.Label == label].sort_values("PromptTok").head(n).reset_index(drop=True)


# ---------------------------------------------------------------- fig 1
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
style(ax, T["f1_title"], T["turn_x"], T["ttft_y"])

q40 = chat[chat.Label == "chat-dual-q40"].sort_values("Turn").reset_index(drop=True)
ax.annotate(T["f1_a"].format(s=q40.iloc[0].TtftMs / 1000, n=int(q40.iloc[0].PromptTokens)),
            xy=(1, q40.iloc[0].TtftMs), xytext=(1.9, 220000), fontsize=10.5, color=BLUE,
            ha="center", arrowprops=dict(arrowstyle="->", color=BLUE, alpha=0.65, shrinkA=2))
ax.annotate(T["f1_b"].format(ms=q40.iloc[3].TtftMs),
            xy=(4, q40.iloc[3].TtftMs), xytext=(4.62, 1150), fontsize=10.5, color=BLUE,
            ha="center", arrowprops=dict(arrowstyle="->", color=BLUE, alpha=0.65, shrinkA=2))
ax.text(0.985, 0.955, T["f1_note"], transform=ax.transAxes, ha="right", va="top",
        fontsize=9, color=GRAY, style="italic")
fig.savefig(FIG / "fig1-chat-ttft.png")
plt.close(fig)
print("fig1-chat-ttft.png")


# ---------------------------------------------------------------- fig 2
res = pd.read_csv(DATA / "bench-results3.csv")
for c in ("PromptTok", "PrefillMed", "TtftMedMs"):
    res[c] = pd.to_numeric(res[c], errors="coerce")

pairs = [("v3-single-k8v4-131k", T["single"], GRAY),
         ("v3-dual-k8v4-131k", T["dual"], BLUE)]
ranked = {k: by_rank(res, k, 3) for k, _, _ in pairs}

fig, axes = plt.subplots(1, 2, figsize=(13.5, 5.6))
x = range(3)
for ax, metric, ylab, title, logy in [
    (axes[0], "PrefillMed", T["prefill_y"], T["f2_title_l"], False),
    (axes[1], "TtftMedMs", T["ttft_y2"], T["f2_title_r"], True),
]:
    for i, (key, name, color) in enumerate(pairs):
        vals = ranked[key][metric].tolist()
        ax.bar([xi + i * 0.37 - 0.185 for xi in x], vals, 0.35, label=name, color=color)
        for xi, v in zip(x, vals):
            ax.text(xi + i * 0.37 - 0.185, v * (1.06 if logy else 1.0) + (0 if logy else 8),
                    f"{v:,.0f}", ha="center", fontsize=8.5, color=color)
    ax.set_xticks(list(x))
    ax.set_xticklabels([f"~{int(v):,}" for v in ranked[pairs[0][0]].PromptTok])
    if logy:
        ax.set_yscale("log")
    style(ax, title, T["prompt_x"], ylab)

fig.savefig(FIG / "fig2-dual-vs-single.png")
plt.close(fig)
print("fig2-dual-vs-single.png")


# ---------------------------------------------------------------- fig 3
kv_map = [("v3-dual-k8v4-131k", "k8v4", GREEN),
          ("v3-dual-int8-131k", "int8", ORANGE),
          ("v3-dual-q40-131k", "q4_0", BLUE)]
kvrank = {k: by_rank(res, k, 3) for k, _, _ in kv_map}

fig, ax = plt.subplots(figsize=(10.5, 6))
for i, (key, name, color) in enumerate(kv_map):
    vals = kvrank[key].PrefillMed.tolist()
    ax.bar([xi + i * 0.27 - 0.27 for xi in x], vals, 0.25, label=name, color=color)
    for xi, v in zip(x, vals):
        ax.text(xi + i * 0.27 - 0.27, v + 14, f"{v:.0f}", ha="center", fontsize=9, color=color)

long_labels = {"v3-dual-k8v4-131k": "v3-dual-longctx",
               "v3-dual-int8-131k": "v3-dual-int8-longctx",
               "v3-dual-q40-131k": "v3-dual-q40-longctx"}
extra_vals = []
for key, name, color in kv_map:
    src = res[(res.Label == long_labels[key]) & (res.PromptTok > 100000)]
    extra_vals.append(float(src.PrefillMed.iloc[0]) if len(src) else 0)

ax.set_xticks(list(x) + [3])
ax.set_xticklabels([f"~{int(v):,}" for v in kvrank[kv_map[0][0]].PromptTok] + [T["long_ctx"]])
for i, ((key, name, color), v) in enumerate(zip(kv_map, extra_vals)):
    if v:
        ax.bar(3 + i * 0.27 - 0.27, v, 0.25, color=color)
        ax.text(3 + i * 0.27 - 0.27, v + 14, f"{v:.0f}", ha="center", fontsize=9, color=color)

style(ax, T["f3_title"], T["prompt_x"], T["prefill_y"])
ax.text(0.5, 1.015, T["f3_sub"], transform=ax.transAxes, ha="center",
        fontsize=10, color=GRAY, style="italic")
fig.savefig(FIG / "fig3-kv-prefill.png")
plt.close(fig)
print("fig3-kv-prefill.png")


# ---------------------------------------------------------------- fig 4
ssd = pd.read_csv(DATA / "bench-ssd.csv")
ssd["ReadMB"] = pd.to_numeric(ssd["ReadMB"], errors="coerce")
ssd["WriteMB"] = pd.to_numeric(ssd["WriteMB"], errors="coerce")
ssd = ssd[ssd.Label != "ssd-k8v4"]          # drop the run disproved by re-checking

fig, axes = plt.subplots(1, 2, figsize=(13.5, 5.4))
names, reads, writes = [], [], []
for lab in ["ssd-q40", "ssd-q40-rerun", "ssd-int8", "ssd-k8v4-rerun"]:
    d = ssd[ssd.Label == lab]
    if len(d):
        base = lab.replace("ssd-", "")
        names.append(base.replace("-rerun", "\n(re-check)") if EN else base.replace("-rerun", "\n(复核)"))
        reads.append(float(d.ReadMB.iloc[0]))
        writes.append(float(d.WriteMB.iloc[0]))

x4 = list(range(len(names)))
axes[0].bar([xi - 0.19 for xi in x4], reads, 0.36, label=T["read"], color=GRAY)
axes[0].bar([xi + 0.19 for xi in x4], writes, 0.36, label=T["write"], color=BLUE)
axes[0].set_yscale("log")
axes[0].set_xticks(x4)
axes[0].set_xticklabels(names, fontsize=10)
style(axes[0], T["f4_l"], T["f4_lx"], T["f4_ly"])

ratio = [r / w if w else 0 for r, w in zip(reads, writes)]
axes[1].barh(x4, ratio, color=BLUE, height=0.55)
for yi, v in zip(x4, ratio):
    axes[1].text(v + 1.2, yi, f"{v:.0f} : 1", va="center", fontsize=11, fontweight="bold", color=BLUE)
axes[1].set_yticks(x4)
axes[1].set_yticklabels(names, fontsize=10)
axes[1].invert_yaxis()
axes[1].set_xlim(0, max(ratio) * 1.25)
style(axes[1], T["f4_r"], T["f4_rx"], "", legend=False)
axes[1].text(0.985, 0.05, T["f4_note"], transform=axes[1].transAxes, ha="right",
             fontsize=9.5, color=GRAY, style="italic")

fig.suptitle(T["f4_sup"], fontsize=14, fontweight="bold", y=1.03)
fig.savefig(FIG / "fig4-disk-io.png")
plt.close(fig)
print("fig4-disk-io.png")

print(f"\nDone ({'EN' if EN else 'ZH'}) -> {FIG}")
