#!/usr/bin/env python3
"""功耗分析：功率口径 + 每 token 能量口径。

为什么要有「每 token 能量」：
A/B 两档的吞吐可能差数倍（B 档不读盘、算得快），此时直接比平均功率
等于把「吞吐差异」混进来。吞吐无关的量是 **J/token**：能量 ÷ token 数。
"""
import json, re, sys, statistics, datetime
from pathlib import Path

# 用法：analyze_jpt.py <结果目录> [--dialogue-tps 20.3,20.5]
#   <结果目录>      pwrbench run 的 --out 目录（含 power.jsonl / blocks.jsonl / launch_*.log）
#   --dialogue-tps  可选。同一设备上日常对话路径的 decode t/s，用逗号分隔；
#                   给了才会打印「跑批 vs 对话」的对比，不给就跳过。
_argv = sys.argv[1:]
_dialogue: list[float] = []
if "--dialogue-tps" in _argv:
    i = _argv.index("--dialogue-tps")
    _dialogue = [float(x) for x in _argv[i + 1].split(",") if x.strip()]
    del _argv[i:i + 2]

OUT = Path(_argv[0] if _argv else "pwrbench_results")
DIALOGUE_TPS = _dialogue

T975 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571}
def t975(df): return T975.get(df, 1.96)

RE_TS = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+ ")
def ts(line):
    m = RE_TS.match(line)
    return datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S") if m else None


def buckets(rows):
    g = {}
    for r in rows:
        g.setdefault(r.get("updateTime"), []).append(r)
    keys = sorted(k for k in g if k is not None)
    out = []
    for i in range(1, len(keys)):
        prev, cur = g[keys[i-1]][-1], g[keys[i]][-1]
        d = (cur["accSysPowerIn"] or 0) - (prev["accSysPowerIn"] or 0)
        c = (cur["accSysCount"] or 0) - (prev["accSysCount"] or 0)
        if c <= 0:
            continue
        batt = statistics.median([x.get("batteryPower_mW") or 0 for x in g[keys[i]]])
        out.append(d / c - batt)
    return out


def block_span(log_path, nrep):
    """推理段时长。

    日志里只有 NSLog 行带时间戳，而 `[BENCH] start/done` 是 print，没有时间戳。
    可用锚点是每轮结束时打印的 `[ENERGY] t0`（带时间戳），它是**每轮的终点**。
    于是：轮周期 = (t_last − t_first)/(n−1)，推理段 ≈ 周期 × n。
    这样自然排除了批前那 2 秒 `-benchIdleSec` 静默。
    """
    rep_ts = []
    for line in log_path.read_text(errors="replace").splitlines():
        t = ts(line)
        if t is not None and "[ENERGY] t0" in line:
            rep_ts.append(t)
    if len(rep_ts) < 2:
        return None, len(rep_ts)
    cycle = (rep_ts[-1] - rep_ts[0]).total_seconds() / (len(rep_ts) - 1)
    return cycle * len(rep_ts), len(rep_ts)


rows = [json.loads(x) for x in (OUT / "power.jsonl").read_text().splitlines() if x.strip()]
blocks = [json.loads(x) for x in (OUT / "blocks.jsonl").read_text().splitlines() if x.strip()]
seg = {}
for r in rows:
    seg.setdefault((r["block"], r["phase"]), []).append(r)

print("=" * 78)
print("iOS 整机功耗测量")
print("=" * 78)

rec = {}
print("\n%-8s %6s %8s %8s %9s %9s %9s %8s" %
      ("块", "轮数", "时长s", "桶数", "功率mW", "待机mW", "J/token", "t/s"))
for b in blocks:
    lab, reps = b["block"], b["reps"]
    span, nrep = block_span(OUT / ("launch_%s.log" % lab), reps)
    run = buckets(seg.get((lab, "run"), []))
    idle = buckets(seg.get((lab, "idle"), []))
    if not run or not span:
        continue
    p_run = statistics.mean(run)
    p_idle = statistics.mean(idle) if idle else 0.0
    ntok = nrep * 256
    jpt = p_run / 1000.0 * span / ntok
    jpt_inc = (p_run - p_idle) / 1000.0 * span / ntok
    rec[lab] = dict(cond=b["cond"], pair=b["pair"], span=span, reps=nrep,
                    p_run=p_run, p_idle=p_idle, ntok=ntok, jpt=jpt,
                    jpt_inc=jpt_inc, tps=b.get("decode_tps"),
                    thermals=b.get("thermals"))
    print("%-8s %6d %8.1f %8d %9.0f %9.0f %9.3f %8s" %
          (lab, reps, span, len(run), p_run, p_idle, jpt, b.get("decode_tps") or "-"))


def paired(key, name, unit=""):
    pairs = sorted({b["pair"] for b in blocks})
    diffs, av, bv = [], [], []
    for p in pairs:
        a = rec.get("A_%d" % p)
        b = rec.get("B_%d" % p)
        if a and b:
            diffs.append(a[key] - b[key])
            av.append(a[key]); bv.append(b[key])
    if not diffs:
        return
    m = statistics.mean(diffs)
    print("\n【%s】A=%.3f  B=%.3f  差 %+.3f %s" % (name, statistics.mean(av), statistics.mean(bv), m, unit))
    print("   逐对: " + " / ".join("%+.3f" % d for d in diffs))
    if len(diffs) >= 2:
        sd = statistics.stdev(diffs)
        half = t975(len(diffs) - 1) * sd / (len(diffs) ** 0.5)
        print("   95%%CI ±%.3f %s（n=%d, t 分布）→ %s"
              % (half, unit, len(diffs), "显著" if abs(m) > half else "⚠️ 跨 0，未达显著"))
        return m, half, statistics.mean(av), statistics.mean(bv)
    return m, None, statistics.mean(av), statistics.mean(bv)


if not rec:
    print("没有可分析的数据块：请确认传入的是 pwrbench run 的 --out 目录，且该次运行完整结束。")
    raise SystemExit(1)

print("\n" + "-" * 78)
print("一、功率口径（每块推理段的平均功率；吞吐不同则不可直接跨设备比较）")
pw = paired("p_run", "平均功率", "mW")

print("\n" + "-" * 78)
print("二、每 token 能量口径（吞吐无关，这台机上应以此为准）")
je = paired("jpt", "每 token 能量", "J/tok")
ji = paired("jpt_inc", "扣掉待机后的每 token 增量能量", "J/tok")

print("\n" + "-" * 78)
print("三、速度（各档 decode t/s）")
for p in sorted({b["pair"] for b in blocks}):
    a, b = rec.get("A_%d" % p), rec.get("B_%d" % p)
    if a and b:
        print("  第 %d 对: A %.1f t/s   B %.1f t/s   (B/A = %.2fx)"
              % (p, a["tps"], b["tps"], b["tps"] / a["tps"]))
atps = [v["tps"] for k, v in rec.items() if k.startswith("A_") and v["tps"]]
if atps:
    print("  A 档平均 %.1f t/s" % statistics.mean(atps))
if DIALOGUE_TPS:
    dlg = statistics.mean(DIALOGUE_TPS)
    print("  日常对话平均 %.2f t/s（%s）"
          % (dlg, " / ".join("%.2f" % v for v in DIALOGUE_TPS)))
    print("  跑批 / 对话 = %.0f%%（跑批比日常对话慢 %.0f%%）"
          % (statistics.mean(atps) / dlg * 100, (1 - statistics.mean(atps) / dlg) * 100))
else:
    print("  （未提供 --dialogue-tps，跳过与日常对话的对比）")


print("\n热状态: " + ", ".join(sorted({t for v in rec.values() for t in (v["thermals"] or [])})) or "-")
