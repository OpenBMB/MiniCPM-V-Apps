# Batch Benchmark — Usage Guide

> Applies to: the `MiniCPM-V-demo` iOS app (MoE models whose expert weights stream from SSD)
> Covers: in-app UI and command-line usage, dataset management, result fields, measurement conventions and troubleshooting
> See also: `scripts/pwrbench/README.md` (whole-device power measurement)

[**中文**](BENCHMARK_zh.md) | English

---

## 1. What it is

A batch benchmark = **fixed dataset × fixed parameters × repeated runs**, executing each case and recording:

| Metric | Meaning |
|---|---|
| prefill tokens / ms / t/s | Input encoding speed (image + prompt) |
| decode tokens / ms / t/s | Per-token output speed |
| TTFT | End-to-end first-token latency (image encode, warm-up, prefill included) |
| TPOT | Average time per output token |
| CPU cycles / instructions, GPU time | Compute-consistency gate (sampled before/after each block) |
| thermal / battery / temperature | Environment state, used to discard thermally throttled runs |

One case = **one image (optional) + one prompt**, single turn, no conversation history.

---

## 2. Quick start

### 2.1 Run from the app UI (recommended)

1. Launch the app and wait for the model to finish loading.
2. Tap the circular button at the bottom-right of the home screen to open **Batch Benchmark**
   (its accessibility label is the screen title; the same entry exists in Settings).
3. From top to bottom:
   - **Dataset** — tap the header to expand; each dataset has a slider choosing how many cases to run this round (`0 … total`, `0` = skip);
   - **Output token limit** — default 512. It only caps the length: generation ends early on EOG, so output length may differ across cases;
   - **Repetitions** — default 1. Cross-case variance is usually much larger than across-repetition variance, so "many cases × few repetitions" estimates the population variance more efficiently;
   - **Start / Cancel / Export last result**;
   - **Progress & statistics** — live progress plus the summary table.
4. When finished, tap "Export last result" and grab the JSON via the share sheet (or copy it out of Files, see §6).

> If an orange temperature warning appears, `MTMDParams.temperature != 0` — results are not reproducible then. Set sampling temperature back to 0 first.

### 2.2 Run from the command line

```bash
UDID=<device UDID>                   # xcrun devicectl list devices
BID=<your app bundle id>            # e.g. com.example.MiniCPMVDemo — use your own build

xcrun devicectl device process launch \
  --device $UDID --terminate-existing $BID \
  -- -bench -benchReps 1 -benchMaxTokens 512 -benchDataset vision_mix_50 -benchStay
```

Everything after `--` is passed to the app as launch arguments. Add `--console` to watch the log live:

```bash
xcrun devicectl device process launch --device $UDID --terminate-existing $BID --console \
  -- -bench -benchReps 1 -benchMaxTokens 512 -benchStay | tee /tmp/bench.log
```

Pull the device-side log afterwards:

```bash
xcrun devicectl device copy from --device $UDID \
  --domain-type appDataContainer --domain-identifier $BID \
  --source Documents/mb_run_log.txt --destination /tmp/mb_run_log.txt
```

> **Where `$BID` comes from**: it is the `PRODUCT_BUNDLE_IDENTIFIER` of *your own* build
> (Xcode's Signing & Capabilities, or `xcodebuild ... PRODUCT_BUNDLE_IDENTIFIER=...`).
> No concrete bundle id is hard-coded in this repository.
> It is only needed **host-side** for launching/terminating the app and copying files
> (`devicectl`, `pwrbench --bundle`). **Running the benchmark from the app UI needs no bundle id** —
> the app never reads its own bundle id.
> For `pwrbench`, pass `--bundle $BID` or export `PWRBENCH_BUNDLE=$BID` once.

---

## 3. Command-line arguments

### 3.1 Benchmark driver

| Argument | Default | Description |
|---|---|---|
| `-bench` | — | **Flag**: enters benchmark mode (otherwise the app opens the chat UI) |
| `-benchReps N` | 1 | Repetitions per case |
| `-benchMaxTokens N` | see note | Output token **upper bound**; generation stops early on EOG. `0` = no limit.<br>When omitted, falls back to `-benchTokens` (below) |
| `-benchTokens N` | **25** | Legacy: **fixed step count, ignores EOG**. Only for strictly equal-length cross-device comparisons.<br>⚠️ Passing neither token argument is equivalent to "fixed 25 steps" |
| `-benchDataset a,b` | `vision_mix_50` | Which datasets to run (comma-separated; each runs to its full count) |
| `-benchCases 1,2,3` | all | Only run the cases with these `key`s (filtered inside the selected datasets) |
| `-benchCooldown sec` | 0 | Inter-repetition cooldown (not exposed in the UI yet) |
| `-benchIdleSec sec` | 0 | Quiet baseline before the run; **`thermal=` lines only appear when > 0** |
| `-benchWarmup 0/1` | 0 | Short warm-up (off by default; text-only datasets fall back to `warmup.png`) |
| `-benchNoReset` | — | **Do not clear KV** before each case (control experiment matching the chat path) |
| `-benchStay` | — | Do not exit after the run; stays in the idle state (power measurement uses it to sample the idle segment) |
| `-openBenchmark` | — | Auto-open the benchmark screen after launch (debug/automation) |

### 3.2 Engine knobs that affect speed/power

| Argument | Default | Description |
|---|---|---|
| `-genSleepMs N` | bench 3 / chat 10 | Yield per decode step. Same case: 10 ms → 17.5 t/s, 3 ms → 22.4 t/s (+28%); an overlong yield drains the GPU queue |
| `-benchTpotMs N` | 0 | Target TPOT (ms/token); used to pace the no-read tier (B) down to tier A |
| `-moeSkipRead` | — | **Skip expert reads** (tier B): reuses stale slot data, same compute path, garbage output |
| `-moeDecodeWindow N` | per-device | Expert cache window (experts resident per layer) |
| `-moeLookaheadDepth N` | 8 | Prefetch depth; `0` disables prefetch. Measured: decode drops from 17.5 to 11.4 t/s (per-token time +55%); not recommended |
| `-moeIoThreads N` | 4 | Parallel read threads |
| `-moeExpertsDir <path>` | default dir | Override the experts file location |

> Authoritative semantics live in the comments at the top of `MBMtmd.mm` / `MiniCPMModelConst.swift`.

---

## 4. Log markers (`--console` or `mb_run_log.txt`)

| Marker | Meaning |
|---|---|
| `[BENCH] start reps=… warmup=… tokens=… cases=… stay=…` | Run starts (emitted via NSLog, so it can be observed live) |
| `[BENCH] dataset=<track> install=<…>` | Dataset in use and the auto-install result |
| `[BENCH] cases=<N> source=<builtin\|documents> track=<…>` | Number of cases actually loaded |
| `[BENCH] summary samples=… ttft_mean=… ttft_ci=… tpot_mean=… prefill_tps=… decode_tps=… repeat_cov=…` | **One summary line per block** (this is what scripts parse) |
| `[BENCH] done` / `[BENCH] stay alive` | Run finished / entering idle |
| `[ENERGY] t0 ret(…)=… energyNJ=… diskRead=… instr=… cycles=…` | Snapshot before each case (timestamped; commonly used as a time anchor) |
| `[ENERGY] phase 图像+预热 / prefill / decode / 整条case: cpuEnergy=… diskRead=… gpuMs=… cpuCycles=… instr=…` | Per-phase machine-side counters (NSLog) |
| `[MBMtmd] perf app: prefill … decode …` | **Per-generation** native accounting (most used) |
| `[MBMtmd] loop split: … llama_decode … sample … gap …` | Decode-loop breakdown (diagnostics) |
| `[moe-ssd] decode #N … miss/hit/bytes/pread/io …` | Expert-read details aggregated per window: every 8 steps in decode, 32 in prefill |

---

## 5. Datasets

### 5.1 Two bundled tracks

| Track | Cases | Content | key range |
|---|---:|---|---|
| **`vision_mix_50`** (default) | 50 | Image recognition / description / short-answer mix (25 reviewed real cases + 25 synthetic short-answer cases) | 3001–3050 |
| `mlperf_llm` | 133 | MLPerf Mobile v6.0: Tiny-MMLU (100) + Tiny-IFEval-33 (33), **text only** | 1001–1100 / 2001–2033 |

The two key ranges do not overlap, so both tracks can run in one block (results are distinguished by `key`).

Selection precedence: CLI `-benchDataset` > plan saved from the UI sliders > default (all of `vision_mix_50`).
A CLI run that passes `-benchDataset` is therefore unaffected by the UI configuration.

### 5.2 Where datasets live

```
Inside the app bundle (read-only):  MiniCPM-V-demo/Resources/Benchmark/<track>/
        ↓ copied automatically at launch (idempotent, guarded by an .installed stamp)
On device Documents:                Documents/benchmark/<track>/cases.jsonl + images (flat)
```

**No manual transfer needed**: datasets ship with the app. To change an image or a prompt, edit the
files under `Documents/benchmark/<track>/` on device (Files app or `devicectl device copy to`) — no rebuild.
If the contents are corrupted, delete that directory and relaunch; it is re-installed automatically.

### 5.3 Custom datasets

One JSON object per line in `Documents/benchmark/<track>/cases.jsonl`:

```json
{"key": 1, "image": "my.png", "text": "Describe the image."}
{"key": 2, "image": null, "text": "Text-only cases set image to null"}
```

- `image` is relative to that directory; `null` means a text-only case;
- images are read as-is (no resizing, no re-encoding) — resolution affects mmproj slicing and first-frame latency;
- to add a new track, register it in `BenchmarkCaseStore.bundledTracks` and drop the directory into `Resources/Benchmark/`.

---

## 6. Result files and conventions

Written to `Documents/benchmark_results/`:

| File | Content |
|---|---|
| `run_<uuid>.json` | Summary (per-repetition detail + statistics + environment metadata + dataset/params).<br>`datasetSource` looks like `documents · vision_mix_50=50,mlperf_llm=0`, which lets you reconstruct the dataset configuration afterwards |
| `telemetry_<uuid>.jsonl` | Per-sample detail, one JSON per line (**aggregation can be redefined later; raw detail cannot be recovered**) |

Pull them off the device:

```bash
xcrun devicectl device copy from --device $UDID \
  --domain-type appDataContainer --domain-identifier $BID \
  --source Documents/benchmark_results --destination /tmp/bench_results
```

### Conventions you must know

1. **`perf app` throughput excludes the inter-step gap**: `decode_ms` accumulates only in-loop time;
   the `Task.sleep` yield (3 ms in bench, 10 ms in chat) is excluded. Under bench defaults,
   wall-clock throughput is about **0.84 ×** the reported value (measured on a 203-token run:
   17.5 t/s reported, 14.9 t/s wall-clock).
2. **The summary's `decode_tps` is the arithmetic mean of per-repetition t/s**, not total tokens ÷ total time.
   Equivalent for equal-length repetitions; an outlier repetition will skew it.
3. **`TTFT` is end-to-end** (image encode + warm-up + prep + prefill), while `prefill_tps` is **pure llama prefill** —
   the two cannot be cross-checked against each other.
4. **Different lengths are not comparable**: longer output means more expert traffic. Either fix `-benchTokens`
   or only compare results under the same `-benchMaxTokens`.
5. **`gpuTimeNs` is always 0 on some iPhones**, so the GPU-time gate is unavailable; use CPU cycles for relative comparison.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Only one token generated | Legacy defect that clamped `decodeTokenLimit` to a minimum of 1; fixed. `-benchMaxTokens 0` means "no limit" |
| `[BENCH] error: no usable case after filtering` | `-benchCases` keys are not in the selected dataset (vision_mix_50 3001–3050, mlperf 1001–2033) |
| Bench throughput below normal chat | Check `-genSleepMs` (bench default is now 3 ms). The previous fixed 10 ms let the GPU drop a DVFS step, costing roughly 22% |
| Progressively slower blocks/runs | Thermal throttling. Inspect `thermal=` and per-run `decode_tps`; increase `-benchCooldown`, reduce repetitions, or lengthen `-benchIdleSec` |
| Text-only dataset: process killed when warm-up is enabled | Historical issue: text-only warm-up triggered a llama_context rebuild and was SIGKILLed. Current versions build the warm-up case from `warmup.png`, or skip warm-up if absent |
| Images reported missing after moving to a new device | Dataset not installed: delete `Documents/benchmark/<track>/` and relaunch, or inspect the `[BENCH] dataset=… install=…` line |
| Meaningless output text in results | `-moeSkipRead` (tier B) was used. By design: identical compute path, unusable content |

---

## 8. Related documents

| Document | Content |
|---|---|
| `scripts/pwrbench/README.md` | Whole-device power measurement (A/B tiers, paired alternation, `pymobiledevice3` sampling) |
| `MiniCPM-V-demo/Resources/Benchmark/*/README.md` | Dataset provenance, construction and licensing |
