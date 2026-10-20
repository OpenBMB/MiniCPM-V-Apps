#!/usr/bin/env python3
"""pwrbench —— iOS 整机功率测量套件（任务 2）

为什么在主机侧而不是 App 内：
    整机功率来自设备 `diagnosticsd` 服务暴露的 `PowerTelemetryData`，
    只有主机（usbmux / 网络）能访问。App 内唯一同类的 IOReport `GPU Energy`
    通道被系统策略拒绝（`deny(1) iokit-open IOReportUserClient`），实测两次均失败。
    所以功率必须由主机采，App 只提供 CPU 能量 / GPU 时长 / 磁盘字节。

三个子命令：probe / run / analyze

分段方式（关键）：
    App 以 `-benchStay` 启动，跑完不退出，于是同一个进程里自然分成三段：
        模型加载 → 推理（[BENCH] start … [BENCH] done）→ 待机（模型驻留、不计算）
    主机侧靠日志里这三行做切分，不需要 App 额外上报时间戳，
    也避开了设备与 Mac 的时钟偏差（用「日志行到达主机的时间」）。
      端口： [BENCH] start            → 推理开始
             [BENCH] done             → 推理结束
             [BENCH] stay alive       → 进入待机

读数口径：
    SystemPowerIn  充电器输入（mW）
    BatteryPower   电池侧（mW）；**正=电池在充电，负=电池在补电**
    整机功率 = SystemPowerIn - BatteryPower

    数据每约 20 秒刷新一次，桶内累加器不变。某个桶的平均功率要用
    「本桶累加器 - 上一桶累加器」除以计数差 —— 桶内相减恒为 0。

用法：
    python3 pwrbench.py probe   --device <UDID>
    python3 pwrbench.py run     --device <UDID> --plan A,B --pairs 3 \
                                --block-seconds 120 --idle-seconds 120 \
                                --tokens 256 --case 2 --out results/
    python3 pwrbench.py analyze --out results/
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

# 目标 App 的 Bundle ID。默认值只是占位，请用 --bundle 或环境变量指定你自己的构建：
#   PWRBENCH_BUNDLE=com.yourorg.MiniCPMVDemo python3 pwrbench.py run ...
DEFAULT_BUNDLE = os.environ.get("PWRBENCH_BUNDLE", "com.example.MiniCPMVDemo")
PYM = "pymobiledevice3"

# 条件名 -> 追加给 App 的启动参数
CONDITION_ARGS = {
    "A": [],                          # 默认：c=128，有 SSD 读
    "B": ["-moeSkipRead"],            # 不读盘，槽位内已有专家直接算（输出垃圾，算力路径不变）
    "C": ["-moeDummyRead"],           # 真读盘但不写进 GPU 槽位
    "D": ["-moeDecodeWindow", "0"],   # 关缓存窗口，每步全 miss
    "F": ["-moeNoMmap"],              # 关 mmap
}

MARK_START = "[BENCH] start"
MARK_DONE = "[BENCH] done"
MARK_STAY = "[BENCH] stay alive"

# 从启动日志里挖出来的「机器侧」证据：GPU 时长、CPU 周期、decode 速度、热状态
# 注：iPhone（iOS 27）上 IOReport 的 GPU 时长通道恒为 0（gpuTimeNs=0），
# 所以算力一致性门禁改用 CPU cycles —— 它来自 pidinfo/rusage，这台机上可用。
RE_PHASE = re.compile(r"\[ENERGY\] phase\s+(.*?):.*?gpuMs=([0-9.]+)"
                      r".*?cpuCycles=([0-9.]+)\s*G.*?instr=([0-9.]+)\s*G")
RE_TPS = re.compile(r"decode_tps=([0-9.]+)")
RE_THERM = re.compile(r"thermal=(\w+)[-→>]+(\w+)")


# ---------------------------------------------------------------- 底层调用

def sh(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout or "", r.stderr or ""
    except FileNotFoundError:
        raise RuntimeError("找不到命令：%s（是否装了 pymobiledevice3？）" % cmd[0])


def read_power():
    """读一次 PowerTelemetryData。

    注意：pymobiledevice3 没有全局 `--udid`，`diagnostics battery single` 也不接受
    设备参数，它自动选中当前连接的那一台。因此要求**同一时刻只连一台设备**。
    `--device` 只用于 xcrun devicectl。
    """
    out, err = sh([PYM, "--no-color", "diagnostics", "battery", "single"])
    if not out.strip():
        if "Device is not connected" in err:
            raise RuntimeError(
                "设备未连接。请确认：\n"
                "  1) iPad 已连上（USB，或与 Mac 同一网络且已信任）\n"
                "  2) 同一时刻只连一台设备（pymobiledevice3 自动选中，没有 --udid）\n"
                "  3) 设备未锁屏休眠")
        raise RuntimeError("battery single 无输出：%s" % err.strip()[-300:])

    j = json.loads(out)
    pt = j.get("PowerTelemetryData")
    if not pt:
        raise RuntimeError("没有 PowerTelemetryData —— 这台设备/系统不暴露整机功率")
    return {
        "wall": time.time(),
        "updateTime": j.get("UpdateTime"),
        "sysPowerIn_mW": pt.get("SystemPowerIn"),
        "sysCurrentIn_mA": pt.get("SystemCurrentIn"),
        "sysVoltageIn_mV": pt.get("SystemVoltageIn"),
        "batteryPower_mW": pt.get("BatteryPower"),
        "accSysPowerIn": pt.get("AccumulatedSystemPowerIn"),
        "accSysCount": pt.get("SystemPowerInAccumulatorCount"),
        "batteryPercent": j.get("CurrentCapacity"),
    }


def find_pid(bundle):
    out, _ = sh([PYM, "--no-color", "developer", "dvt", "proclist"], timeout=120)
    try:
        procs = json.loads(out)
    except Exception:
        return None
    for p in procs:
        if p.get("bundleIdentifier") == bundle:
            return p.get("pid")
    return None


def kill_app(bundle):
    pid = find_pid(bundle)
    if pid:
        sh([PYM, "--no-color", "developer", "dvt", "kill", str(pid)], timeout=90)


def launch(device, bundle, args, log_path):
    cmd = ["xcrun", "devicectl", "device", "process", "launch",
           "--device", device, "--console", "--terminate-existing", "-t", "5400",
           bundle, "--"] + list(args)
    return subprocess.Popen(cmd, stdout=open(log_path, "w"), stderr=subprocess.STDOUT)


class LogWatcher(object):
    """增量读取启动日志，用来识别三段之间的分界。"""

    def __init__(self, path):
        self.path = Path(path)
        self.pos = 0

    def drain(self):
        if not self.path.exists():
            return []
        with open(self.path, "r", errors="replace") as f:
            f.seek(self.pos)
            chunk = f.read()
            self.pos = f.tell()
        return chunk.splitlines()


# ---------------------------------------------------------------- 跑一个条件

def tpot_for(a, cond):
    """本档位的目标 TPOT（毫秒/token）。0 = 不配速。

    典型用法 `--tpot B:41`：A 档不配速（自然最快），B 档压到 ~24 t/s，
    和 A（22.4 t/s）只差 10% 以内，两档 GPU 占空比才可比。
    """
    spec = getattr(a, "tpot_spec", None)
    if isinstance(spec, dict):
        return spec.get(cond, 0)
    if isinstance(spec, int):
        return spec
    return 0


def reps_for(a, cond):
    """本档位的轮数。

    - 不指定：按「每轮 42 秒」折算（iPad 口径，M1 实测）
    - `--reps 4`：所有档位同一轮数
    - `--reps A:4,B:10`：按档位给。iPhone 上 B 档一轮只要 12 秒（A 档 28 秒），
      用同样轮数的话 B 的采样窗口太短，20 秒功率桶只剩 2 个 —— 必须给 B 更多轮。
    """
    spec = getattr(a, "reps_spec", None)
    if isinstance(spec, dict):
        if cond in spec:
            return spec[cond]
        return max(1, int(round(a.block_seconds / 42.0)))
    if isinstance(spec, int) and spec > 0:
        return spec
    return max(1, int(round(a.block_seconds / 42.0)))


def run_condition(a, raw, cond, pair):
    """跑一个条件：推理 block_seconds 秒，随后待机 idle_seconds 秒。"""
    label = "%s_%d" % (cond, pair)
    log_path = Path(a.out) / ("launch_%s.log" % label)

    kill_app(a.bundle)
    time.sleep(2)

    reps = reps_for(a, cond)
    args = ["-bench", "-benchReps", str(reps), "-benchWarmup", "0",
            "-benchMaxTokens", str(a.tokens), "-benchCases", str(a.case),
            "-benchIdleSec", str(getattr(a, "bench_idle", 0)), "-benchStay"] + CONDITION_ARGS[cond]
    if getattr(a, "cooldown", 0):
        args += ["-benchCooldown", str(a.cooldown)]
    if getattr(a, "no_reset", False):
        args += ["-benchNoReset"]
    if getattr(a, "gen_sleep", None) is not None:
        args += ["-genSleepMs", str(a.gen_sleep)]
    if getattr(a, "track", None):
        args += ["-benchDataset", a.track]
    tpot = tpot_for(a, cond)
    if tpot:
        args += ["-benchTpotMs", str(tpot)]
    print("    reps=%d cooldown=%ss" % (reps, getattr(a, "cooldown", 0)))

    proc = launch(a.device, a.bundle, args, log_path)
    watcher = LogWatcher(log_path)

    phase = "load"
    t_idle = None
    t_launch = time.time()
    counts = {"load": 0, "run": 0, "idle": 0}
    gpu_ms = 0.0
    cycles_g = 0.0
    instr_g = 0.0
    decode_tps = None
    thermals = []

    def handle(lines):
        nonlocal phase, t_idle, gpu_ms, cycles_g, instr_g, decode_tps
        for line in lines:
            if MARK_START in line and phase == "load":
                phase = "run"
                print("    推理开始")
            elif MARK_DONE in line and phase == "run":
                phase = "idle"
                t_idle = time.time()
                print("    推理结束，进入待机")
            elif MARK_STAY in line:
                pass

            m = RE_PHASE.search(line)
            if m and m.group(1).strip() == "decode":
                gpu_ms += float(m.group(2))
                cycles_g += float(m.group(3))
                instr_g += float(m.group(4))
            m = RE_TPS.search(line)
            if m:
                decode_tps = float(m.group(1))
            m = RE_THERM.search(line)
            if m:
                thermals.append(m.group(2))

    with open(raw, "a") as f:
        while True:
            handle(watcher.drain())

            if phase == "idle" and t_idle and (time.time() - t_idle) >= a.idle_seconds:
                break
            if time.time() - t_launch > a.timeout:
                print("    ⚠️ 超时退出")
                break

            try:
                s = read_power()
                s["block"] = label
                s["phase"] = phase
                f.write(json.dumps(s) + "\n")
                f.flush()
                counts[phase] += 1
            except Exception as e:
                print("    采样失败: %s" % e, file=sys.stderr)

            # 分片等待，期间持续把日志读走。
            #
            # devicectl --console 把 App 的 stdout 接到管道，而 App 在 -bench 下
            # 显式设了无缓冲（setvbuf(_IONBF)）。实测推理段每 5 秒要吐 ~67 KB
            # （157 KB / 203 token），超过管道缓冲（64 KB）；这里如果整段 sleep，
            # App 的 print() 会阻塞在 write() 上 —— 每步被拖慢几毫秒，
            # 表现为「bench 比日常对话稳定慢 10%」。分片 drain 就不会堵。
            waited = 0.0
            while waited < a.interval:
                handle(watcher.drain())
                time.sleep(0.2)
                waited += 0.2

    kill_app(a.bundle)
    print("    样本: 推理 %d / 待机 %d" % (counts["run"], counts["idle"]))

    stats = {"block": label, "cond": cond, "pair": pair, "reps": reps,
             "gpu_ms": gpu_ms, "cycles_g": cycles_g, "instr_g": instr_g,
             "decode_tps": decode_tps, "thermals": sorted(set(thermals))}
    with open(Path(a.out) / "blocks.jsonl", "a") as f:
        f.write(json.dumps(stats) + "\n")
    print("    CPU %.2f G cycles / %.2f G instr (gpuMs=%.0f) | decode_tps=%s | thermal=%s"
          % (cycles_g, instr_g, gpu_ms, decode_tps,
             ",".join(stats["thermals"]) or "-"))
    return stats


# ---------------------------------------------------------------- 分桶与统计

def buckets(rows):
    """把一段采样切成 20 秒桶，返回每桶整机功率（mW）。

    桶内累加器不变，必须用「相邻桶之差」。
    """
    if len(rows) < 2:
        return []
    groups = {}
    for r in rows:
        groups.setdefault(r.get("updateTime"), []).append(r)

    keys = sorted(k for k in groups if k is not None)
    out = []
    for i in range(1, len(keys)):
        prev = groups[keys[i - 1]][-1]
        cur = groups[keys[i]][-1]
        d = (cur.get("accSysPowerIn") or 0) - (prev.get("accSysPowerIn") or 0)
        c = (cur.get("accSysCount") or 0) - (prev.get("accSysCount") or 0)
        if c <= 0:
            continue
        batt = statistics.median([x.get("batteryPower_mW") or 0 for x in groups[keys[i]]])
        out.append(d / c - batt)      # 电池在充电时 batt 为正 → 扣除；补电时为负 → 加回
    return out


def describe(v):
    if not v:
        return {"n": 0}
    return {"n": len(v), "mean": statistics.mean(v), "median": statistics.median(v),
            "sd": statistics.stdev(v) if len(v) > 1 else 0.0,
            "min": min(v), "max": max(v)}


# ---------------------------------------------------------------- 子命令

def cmd_probe(a):
    s = read_power()
    print("设备: %s" % a.device)
    print("  SystemPowerIn   = %s mW" % s["sysPowerIn_mW"])
    print("  SystemCurrentIn = %s mA" % s["sysCurrentIn_mA"])
    print("  SystemVoltageIn = %s mV" % s["sysVoltageIn_mV"])
    print("  BatteryPower    = %s mW  (正=充电，负=补电)" % s["batteryPower_mW"])
    print("  电量 = %s%%" % s["batteryPercent"])

    i, v, p = s["sysCurrentIn_mA"], s["sysVoltageIn_mV"], s["sysPowerIn_mW"]
    if i and v and p:
        calc = i / 1000.0 * v / 1000.0 * 1000.0
        print("  校验: %d mA × %d mV = %.0f mW（读到 %d mW，差 %.1f%%）"
              % (i, v, calc, p, abs(calc - p) / p * 100))

    batt = s["batteryPower_mW"] or 0
    print("  当前整机功率 ≈ %d mW" % (p - batt))
    print("\n结论: 字段可用，可以跑 run。")


def _parse_reps(s):
    """'4' -> 4；'A:4,B:10' -> {'A':4,'B':10}；'0'/非法 -> 0（走 42s 折算）"""
    s = str(s).strip()
    if ":" in s:
        d = {}
        for part in s.split(","):
            k, _, v = part.partition(":")
            k = k.strip().upper()
            if k and v.strip().isdigit():
                d[k] = max(1, int(v))
        return d or 0
    return max(0, int(s)) if s.isdigit() else 0


def cmd_run(a):
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    a.reps_spec = _parse_reps(a.reps)
    a.tpot_spec = _parse_reps(getattr(a, "tpot", "0"))
    raw = out / "power.jsonl"
    blocks = out / "blocks.jsonl"
    if a.fresh:
        for p in (raw, blocks):
            if p.exists():
                p.unlink()

    plan = [c.strip() for c in a.plan.split(",") if c.strip()]
    unknown = [c for c in plan if c not in CONDITION_ARGS]
    if unknown:
        sys.exit("未知条件: %s（可选 %s）" % (unknown, list(CONDITION_ARGS)))

    per = (a.block_seconds + a.idle_seconds + a.load_seconds) * len(plan)
    print("计划: %d 对 × [%s]，推理 %ds + 待机 %ds"
          % (a.pairs, "→".join(plan), a.block_seconds, a.idle_seconds))
    print("预计总时长: %.0f 分钟" % (per * a.pairs / 60.0))
    print("每块轮数: " + "  ".join("%s=%d" % (c, reps_for(a, c)) for c in plan))
    print("热保护: 同一档位 decode 速度相对首块下降 >%.0f%% → 追加冷却 %ds；"
          ">%.0f%% 或 thermal=critical → 立即停止\n"
          % (a.thermal_drop * 100, a.thermal_extra, a.thermal_drop * 2 * 100))

    base_tps = {}     # cond -> 首块 decode_tps（同档位内的热漂移基准）
    for pair in range(a.pairs):
        for cond in plan:
            print("[%s_%d] 开始" % (cond, pair))
            st = run_condition(a, raw, cond, pair)

            # ── 热保护：iPhone 无风扇，积热会先表现为降速，再表现为崩溃 ──
            worst = ""
            seen = st.get("thermals") or []
            for lv in ("critical", "serious", "fair", "nominal"):
                if lv in seen:
                    worst = lv
                    break
            if worst == "critical":
                sys.exit("\n🛑 设备热状态 critical，立即停止（避免热崩关机）。"
                         "请让设备冷却后再跑，并加长 --idle-seconds。")

            tps = st.get("decode_tps")
            if tps and cond not in base_tps:
                base_tps[cond] = tps
            elif tps and base_tps.get(cond):
                drop = 1.0 - tps / base_tps[cond]
                if drop > a.thermal_drop * 2:
                    sys.exit("\n🛑 %s 档 decode 速度 %.1f → %.1f t/s（降 %.0f%%），"
                             "判定为热节流，立即停止。" % (cond, base_tps[cond], tps, drop * 100))
                if drop > a.thermal_drop:
                    print("    ⚠️ decode 速度降 %.0f%%，追加冷却 %ds"
                          % (drop * 100, a.thermal_extra))
                    time.sleep(a.thermal_extra)
            print("")

    print("采样完成: %s" % raw)
    cmd_analyze(argparse.Namespace(out=str(out)))


T975 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
        7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179,
        13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101,
        19: 2.093, 20: 2.086}


def t975(df):
    if df < 1:
        return float("nan")
    return T975.get(df, 1.96)


def cmd_analyze(a):
    raw = Path(a.out) / "power.jsonl"
    if not raw.exists():
        sys.exit("找不到 %s" % raw)

    rows = [json.loads(x) for x in raw.read_text().splitlines() if x.strip()]
    seg = {}
    for r in rows:
        seg.setdefault((r.get("block", "?"), r.get("phase", "?")), []).append(r)

    # block(如 A_0) -> {phase: 统计}
    per_block = {}
    lines = ["# 整机功率测量报告", "",
             "| 块 | 阶段 | 桶数 | 均值 mW | 中位 mW | sd | 区间 |",
             "|---|---|---:|---:|---:|---:|---|"]
    print("\n%-10s %-6s %5s %10s %10s %8s %s"
          % ("块", "阶段", "桶数", "均值mW", "中位mW", "sd", "区间"))
    for (label, phase) in sorted(seg, key=lambda k: (_cond_key(k[0]), k[0], k[1])):
        d = describe(buckets(seg[(label, phase)]))
        if d["n"] == 0:
            continue
        per_block.setdefault(label, {})[phase] = d
        print("%-10s %-6s %5d %10.0f %10.0f %8.0f  %.0f~%.0f"
              % (label, phase, d["n"], d["mean"], d["median"], d["sd"], d["min"], d["max"]))
        lines.append("| %s | %s | %d | %.0f | %.0f | %.0f | %.0f~%.0f |"
                     % (label, phase, d["n"], d["mean"], d["median"], d["sd"], d["min"], d["max"]))

    # ── 机器侧校验：A/B 算力是否一致、有没有热节流 ──
    bpath = Path(a.out) / "blocks.jsonl"
    if bpath.exists():
        bstats = [json.loads(x) for x in bpath.read_text().splitlines() if x.strip()]
        if bstats:
            # iPhone 上 gpuMs 恒为 0，退化为 CPU cycles 做「算力一致性」门禁
            use_gpu = any((b.get("gpu_ms") or 0) > 0 for b in bstats)
            key = "gpu_ms" if use_gpu else "cycles_g"
            title = "GPU decode ms" if use_gpu else "CPU cycles G"
            lines += ["", "## 机器侧校验（App 日志）", "",
                      "| 块 | reps | %s | decode t/s | 热状态 |" % title,
                      "|---|---:|---:|---:|---|"]
            print("\n%-10s %5s %14s %11s  %s" % ("块", "reps", title, "decode t/s", "热状态"))
            for b in sorted(bstats, key=lambda x: (_split(x["block"])[0], x["block"])):
                lines.append("| %s | %s | %.2f | %s | %s |"
                             % (b["block"], b["reps"], b.get(key) or 0,
                                b.get("decode_tps") or "-",
                                ",".join(b.get("thermals") or []) or "-"))
                print("%-10s %5s %14.2f %11s  %s"
                      % (b["block"], b["reps"], b.get(key) or 0,
                         b.get("decode_tps") or "-",
                         ",".join(b.get("thermals") or []) or "-"))

            work = {}
            tps = {}
            for b in bstats:
                if b.get(key):
                    work.setdefault(b["cond"], []).append(b[key])
                if b.get("decode_tps"):
                    tps.setdefault(b["cond"], []).append(b["decode_tps"])
            gate = []
            if "A" in work and "B" in work:
                ga, gb = statistics.mean(work["A"]), statistics.mean(work["B"])
                d = abs(ga - gb) / max(ga, gb) * 100
                gate.append("- A/B 的%s：A %.2f vs B %.2f，差 **%.1f%%** → %s"
                            % (title, ga, gb, d, "✅ 通过（<5%，做差成立）"
                               if d < 5 else "❌ 不通过：算力不一致，A−B 不能归因给搬运"))
            if not use_gpu:
                gate.append("- ⚠️ 本机 `gpuTimeNs` 恒为 0，无法用 GPU 时长做门禁，"
                            "已改用 CPU cycles 近似（同一进程、同一 case，可做相对比较）")
            for c in sorted(tps):
                if len(tps[c]) > 1:
                    gate.append("- %s 档 decode 速度 %.1f ~ %.1f t/s（首块 %.1f）"
                                % (c, min(tps[c]), max(tps[c]), tps[c][0]))
            if gate:
                lines += [""] + gate
                print("\n".join(gate))

    report = Path(a.out) / "report.md"
    report.write_text("\n".join(lines) + "\n")
    print("\n报告: %s" % report)

    text = _conclude(per_block)
    print(text)
    with open(report, "a") as f:
        f.write(text)


def _split(label):
    """A_0 -> ("A", 0)"""
    cond, _, idx = label.rpartition("_")
    try:
        return cond, int(idx)
    except ValueError:
        return label, 0


def _conclude(per_block):
    """按条件聚合（同一条件的多对取均值），并给出配对差值与 t 分布区间。"""
    run_by_pair = {}     # (cond, pair) -> 中位
    idle_by_pair = {}
    for label, phases in per_block.items():
        cond, pair = _split(label)
        if "run" in phases:
            run_by_pair[(cond, pair)] = phases["run"]["median"]
        if "idle" in phases:
            idle_by_pair[(cond, pair)] = phases["idle"]["median"]

    def mean_of(cond, table):
        v = [x for (c, _), x in table.items() if c == cond]
        return statistics.mean(v) if v else None

    A = mean_of("A", run_by_pair)
    B = mean_of("B", run_by_pair)
    idles = [x for x in idle_by_pair.values()]

    lines = ["", "## 结论", ""]
    if A:
        lines.append("- A 档（计算+搬运）: **%.0f mW**" % A)
    if B:
        lines.append("- B 档（纯计算）:     **%.0f mW**" % B)
    if idles:
        im = statistics.mean(idles)
        lines.append("- 待机（模型驻留、不计算）: **%.0f mW**" % im)
        if B:
            lines.append("- 纯计算 = B − 待机 = **%.0f mW**" % (B - im))

    pairs = sorted(set(p for (c, p) in run_by_pair if c == "A") &
                   set(p for (c, p) in run_by_pair if c == "B"))
    if pairs:
        diffs = [run_by_pair[("A", p)] - run_by_pair[("B", p)] for p in pairs]
        m = statistics.mean(diffs)
        lines.append("")
        lines.append("配对差值: " + " / ".join("%+.0f" % d for d in diffs) + " mW")
        if len(diffs) >= 2:
            sd = statistics.stdev(diffs)
            half = t975(len(diffs) - 1) * sd / (len(diffs) ** 0.5)
            lines.append("- **SSD 搬运 = A − B = %+.0f mW**，95%% CI ±%.0f mW"
                         "（n=%d 对, t 分布）" % (m, half, len(diffs)))
            if abs(m) < half:
                lines.append("- ⚠️ 区间跨过 0：未达显著，需增加对数或加长每块")
        else:
            lines.append("- SSD 搬运 = A − B = %+.0f mW（仅 %d 对，无置信区间）" % (m, len(diffs)))

        if A:
            lines.append("")
            lines.append("**占比（注意三个分母不同）**")
            lines.append("- 占满载:      (A−B)/A = **%.1f%%**" % (m / A * 100))
            if B:
                lines.append("- 比不做搬运时多: (A−B)/B = **%.1f%%**  ← 通常问的是这个"
                             % (m / B * 100))
            if B and idles and (B - im) > 0:
                lines.append("- 相当于计算增量: (A−B)/(B−待机) = %.1f%%"
                             % (m / (B - im) * 100))

    lines += ["", "> 口径：整机输入功率，含屏幕/CPU/GPU/DRAM/闪存；",
              "> 电池侧无累加器，用桶内瞬时快照中位数近似，差值为几百毫瓦量级，按量级解读。"]
    return "\n".join(lines) + "\n"


def _cond_key(label):
    return label


# ---------------------------------------------------------------- 入口

def main():
    p = argparse.ArgumentParser(description="iOS 整机功率测量套件")
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--device", required=True, help="设备 UDID（仅 devicectl 用）")
    common.add_argument("--bundle", default=DEFAULT_BUNDLE, help="App bundle id")

    sp = sub.add_parser("probe", parents=[common], help="确认字段可用")
    sp.set_defaults(func=cmd_probe)

    sr = sub.add_parser("run", parents=[common], help="跑条件序列并采样")
    sr.add_argument("--plan", default="A,B", help="条件序列，如 A,B")
    sr.add_argument("--pairs", type=int, default=3, help="重复多少对")
    sr.add_argument("--block-seconds", type=int, default=120, help="推理段时长")
    sr.add_argument("--idle-seconds", type=int, default=120, help="待机段时长（兼作冷却）")
    sr.add_argument("--load-seconds", type=int, default=90, help="模型加载预估（仅用于估时）")
    sr.add_argument("--timeout", type=int, default=900, help="单条件总超时")
    sr.add_argument("--tokens", type=int, default=256,
                    help="输出 token 的**上限**（-benchMaxTokens）：模型撞 EOG 会提前停，"
                         "不会像旧的 -benchTokens 那样强行补到上限。0 = 不设上限")
    sr.add_argument("--case", type=int, default=2)
    sr.add_argument("--interval", type=float, default=5.0, help="采样间隔")
    sr.add_argument("--reps", default="0",
                    help="每块推理轮数。0=按每轮 42s 折算（iPad 口径）；"
                         "数字=所有档位同轮数；也可按档位给，如 A:4,B:10"
                         "（iPhone 上 B 档一轮 12s、A 档 28s，B 需要更多轮才有够用的功率桶）")
    sr.add_argument("--cooldown", type=int, default=0,
                    help="轮间暂停秒数（-benchCooldown）：拉长采样窗口又不连续满载")
    sr.add_argument("--bench-idle", type=int, default=0,
                    help="批前静默秒数（-benchIdleSec）；>0 才会打印 thermal= 行")
    sr.add_argument("--thermal-drop", type=float, default=0.10,
                    help="同档 decode 速度相对首块的下降阈值，超过即追加冷却")
    sr.add_argument("--thermal-extra", type=int, default=120, help="触发热保护后追加的冷却秒数")
    sr.add_argument("--tpot", default="0",
                    help="目标 TPOT（毫秒/token），用于把 B 档限速到 A 档水平。"
                         "支持按档位：`B:41`（=24.4 t/s）。0/不填 = 不配速")
    sr.add_argument("--gen-sleep", type=int, default=None,
                    help="覆盖 decode 循环让出毫秒数（-genSleepMs）。"
                         "不填 = 按路径默认（bench 3ms / 对话 10ms）")
    sr.add_argument("--track", default=None,
                    help="数据集 track（-benchDataset）：mmmu_qa_100（默认，100 条图文）/ mlperf_llm（133 条纯文本）")
    sr.add_argument("--no-reset", action="store_true",
                    help="加 -benchNoReset：每条 case 前不清 KV（对齐日常对话路径；"
                         "对话从来不调 clearKVCacheForNewTurn）")
    sr.add_argument("--out", default="pwrbench_results")
    sr.add_argument("--fresh", action="store_true", default=True, help="覆盖旧采样")
    sr.set_defaults(func=cmd_run)

    sa = sub.add_parser("analyze", help="解析已有采样")
    sa.add_argument("--out", default="pwrbench_results")
    sa.set_defaults(func=cmd_analyze)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
