# 批量基准测试（Batch Benchmark）使用说明

> 适用：`MiniCPM-V-demo` iOS App（专家权重从 SSD 流式读取的 MoE 模型）
> 覆盖：App 界面与命令行的运行方式、数据集管理、结果字段、度量口径与常见问题排查
> 相关文档：`scripts/pwrbench/README.md`（整机功率测量）

[**English**](BENCHMARK.md) | 中文

> ⚠️ **建议使用 Release 构建。**
> Debug 构建会导致性能下降，并可能出现不确定的报错。
> Xcode 里：**Product → Scheme → Edit Scheme → Run → Build Configuration 改成 Release**；
> 命令行：`-configuration Release`。

---

## 1. 这是什么

批量基准测试 = **固定的数据集 × 固定参数 × 多轮重复**，逐条跑推理并记录：

| 指标 | 含义 |
|---|---|
| prefill tokens / ms / t/s | 输入（图 + 提示词）编码速度 |
| decode tokens / ms / t/s | 输出逐 token 速度 |
| TTFT | 首 token 端到端时延（含图编码、预热、prefill） |
| TPOT | 平均每输出 token 耗时 |
| CPU cycles / instructions、GPU 时长 | 算力一致性门禁（跑批前后各采一次） |
| thermal / 电量 / 温度 | 环境状态，用于剔除被热节流污染的轮次 |

**一条 case = 一张图（可选）+ 一段提示词**，单轮、无对话历史。

---

## 2. 快速开始

### 2.1 用 App 界面跑（推荐）

1. 启动 App，等模型加载完成（首页出现输入框）。
2. 点首页右下角的圆形按钮进入「批量基准测试」（无障碍标签即该页标题；设置页内也有同名入口）。
3. 界面自上而下：
   - **数据集**：点标题行展开 → 每条数据集一个滑条，决定本次跑多少条（`0 ~ 该数据集总条数`，0 = 不跑）；
   - **输出 token 上限**：默认 512。仅限制上限，遇到 EOG 提前结束，因此不同 case 的输出长度可以不同；
   - **重复轮数**：默认 1。跨 case 的方差通常显著大于同 case 重复间的方差，「多 case × 少重复」对总体方差的估计效率更高；
   - **开始跑批 / 取消 / 导出最近一次结果**；
   - **进度与统计**：实时进度 + 汇总表。
4. 跑完点「导出最近一次结果」，用系统分享面板取走 JSON（或直接从 Files App 里拿，见 §6）。

> 界面顶部若出现橙色温度警告，说明 `MTMDParams.temperature != 0`，此时结果不可复现，请先把采样温度改回 0。

### 2.2 用命令行跑

```bash
UDID=<设备 UDID>                     # xcrun devicectl list devices 查
BID=<你的 App Bundle ID>          # 例如 com.example.MiniCPMVDemo（改成你自己构建的）

xcrun devicectl device process launch \
  --device $UDID --terminate-existing $BID \
  -- -bench -benchReps 1 -benchMaxTokens 512 -benchDataset vision_mix_50 -benchStay
```

`--` 之后是 App 的启动参数。追加 `--console` 可在主机侧实时查看日志：

```bash
xcrun devicectl device process launch --device $UDID --terminate-existing $BID --console \
  -- -bench -benchReps 1 -benchMaxTokens 512 -benchStay | tee /tmp/bench.log
```

跑完把设备日志取回来：

```bash
xcrun devicectl device copy from --device $UDID \
  --domain-type appDataContainer --domain-identifier $BID \
  --source Documents/mb_run_log.txt --destination /tmp/mb_run_log.txt
```

> **`$BID` 从哪来**：它是你自己构建时的 `PRODUCT_BUNDLE_IDENTIFIER`（Xcode 的 Signing & Capabilities
> 或 `xcodebuild ... PRODUCT_BUNDLE_IDENTIFIER=...`）。仓库里不写死任何具体包名。
> 这一项**只影响主机侧的启停与文件拷贝**（命令行的 `devicectl` / `pwrbench --bundle`），
> **App 界面里跑批完全不需要它** —— App 自身不读取自己的 bundle id。
> 用 `pwrbench` 时同样要指定：`--bundle $BID`，或设一次环境变量 `export PWRBENCH_BUNDLE=$BID`。

---

## 3. 命令行参数全表

### 3.1 跑批本身

| 参数 | 缺省 | 说明 |
|---|---|---|
| `-bench` | — | **开关**：带它才进入跑批模式（否则正常进聊天界面） |
| `-benchReps N` | 1 | 每条 case 重复几轮 |
| `-benchMaxTokens N` | 见说明 | 输出 token **上限**，遇到 EOG 提前结束。`0` = 不设上限。<br>未指定时回退到 `-benchTokens`（见下） |
| `-benchTokens N` | **25** | 旧口径：**固定步数、忽略 EOG**。仅在需要严格等长的跨设备对比时用。<br>⚠️ 两个 token 参数都不传时，等价于「固定生成 25 步」 |
| `-benchDataset a,b` | `vision_mix_50` | 要运行的数据集，逗号分隔；每条 track 运行其全部 case |
| `-benchCases 1,2,3` | 全部 | 只跑指定 `key` 的 case（在所选数据集内过滤） |
| `-benchCooldown 秒` | 0 | 轮间冷却（防热节流；UI 上暂未暴露） |
| `-benchIdleSec 秒` | 0 | 跑批前静默基线时长；**>0 才会打印 `thermal=` 行** |
| `-benchWarmup 0/1` | 0 | 短预热（默认关；纯文本数据集开预热会借 `warmup.png`） |
| `-benchNoReset` | — | 每条 case 前**不清 KV**（对齐日常对话路径的对照实验） |
| `-benchStay` | — | 运行结束后不退出进程，停留在待机状态（功耗测量依赖它继续采样待机段） |
| `-openBenchmark` | — | 启动后自动跳到跑批界面（调试/自动化用） |

### 3.2 影响速度/功耗的引擎参数（跑批场景常用）

| 参数 | 缺省 | 说明 |
|---|---|---|
| `-genSleepMs N` | bench 3 / 对话 10 | decode 循环每步让出毫秒数。同一 case 实测：10 ms → 17.5 t/s，3 ms → 22.4 t/s（+28%）；让出过久会抽空 GPU 队列 |
| `-benchTpotMs N` | 0 | 目标 TPOT（ms/token），用于把不读盘的 B 档限速到 A 档水平 |
| `-moeSkipRead` | — | **跳过专家读盘**（B 档）：复用槽位中已有数据，算力路径一致，输出内容不可用 |
| `-moeDecodeWindow N` | 设备分档 | 专家缓存窗口（每层常驻多少个专家） |
| `-moeLookaheadDepth N` | 8 | 预读深度；`0` = 关闭预读。实测关闭后 decode 由 17.5 降至 11.4 t/s（每 token 耗时 +55%），不建议关闭 |
| `-moeIoThreads N` | 4 | 并行读盘线程数 |
| `-moeExpertsDir <path>` | 默认目录 | 指定 experts 文件位置 |

> 引擎参数的完整语义见 `MBMtmd.mm` / `MiniCPMModelConst.swift` 顶部注释。

---

## 4. 日志标记（`--console` 或 `mb_run_log.txt`）

| 标记 | 含义 |
|---|---|
| `[BENCH] start reps=… warmup=… tokens=… cases=… stay=…` | 跑批开始（经 NSLog 输出，可实时观察） |
| `[BENCH] dataset=<track> install=<…>` | 本次用的数据集与自动安装结果 |
| `[BENCH] cases=<N> source=<builtin\|documents> track=<…>` | 实际加载的 case 条数 |
| `[BENCH] summary samples=… ttft_mean=… ttft_ci=… tpot_mean=… prefill_tps=… decode_tps=… repeat_cov=…` | **每块结束时的一行汇总**（脚本解析这一行） |
| `[BENCH] done` / `[BENCH] stay alive` | 跑完 / 进入待机 |
| `[ENERGY] t0 ret(…)=… energyNJ=… diskRead=… instr=… cycles=…` | 每条 case 开始前的快照（带时间戳，常用作时间锚点） |
| `[ENERGY] phase 图像+预热 / prefill / decode / 整条case: cpuEnergy=… diskRead=… gpuMs=… cpuCycles=… instr=…` | 分阶段机器侧计量（NSLog） |
| `[MBMtmd] perf app: prefill … decode …` | **单次生成**的原生计量（最常用） |
| `[MBMtmd] loop split: … llama_decode … sample … 步间隔 …` | decode 循环分段计时（诊断用） |
| `[moe-ssd] decode #N … miss/hit/bytes/pread/io …` | 专家读盘明细，按窗口聚合：decode 每 8 步、prefill 每 32 步 |

---

## 5. 数据集

### 5.1 内置两条 track

| track | 条数 | 内容 | key 段 |
|---|---:|---|---|
| **`vision_mix_50`**（默认） | 50 | 识图 / 描述 / 短答为主的图文混合（25 条已审核真实 case + 25 条自造短答） | 3001~3050 |
| `mlperf_llm` | 133 | MLPerf Mobile v6.0：Tiny-MMLU(100) + Tiny-IFEval-33(33)，**纯文本** | 1001~1100 / 2001~2033 |

两条 track 的 key 段不重叠，可以同时跑（结果里靠 `key` 区分）。

选择优先级：命令行 `-benchDataset` > 界面滑条保存的选择 > 默认（`vision_mix_50` 全量）。
即带 `-benchDataset` 的命令行运行不受界面配置影响。

### 5.2 数据集的来源与存放位置

```
App 包内（只读）：  MiniCPM-V-demo/Resources/Benchmark/<track>/
        ↓ App 启动时自动铺（幂等，带 .installed 戳记）
设备 Documents：    Documents/benchmark/<track>/cases.jsonl + 图片（同级扁平）
```

**不需要手动传文件**：数据集随 App 分发，装完 App 就有了。想改图或改提示词，直接改设备上
`Documents/benchmark/<track>/` 里的文件即可（Files App 或 `devicectl device copy to`），不用重编译；
若内容被改坏，删除该目录后重启 App 即会自动恢复。

### 5.3 自定义数据集

在 `Documents/benchmark/<track>/cases.jsonl` 里一行一条：

```json
{"key": 1, "image": "my.png", "text": "请描述图片中的内容。"}
{"key": 2, "image": null, "text": "纯文本 case 把 image 写成 null"}
```

- `image` 相对该目录；`null` = 纯文本 case；
- 图片原样读取（不缩放、不重编码），分辨率会影响 mmproj 切片与首帧耗时；
- 新增 track 需要在 `BenchmarkCaseStore.bundledTracks` 里登记，并把目录放进 `Resources/Benchmark/`。

---

## 6. 结果文件与口径

落盘位置：`Documents/benchmark_results/`

| 文件 | 内容 |
|---|---|
| `run_<uuid>.json` | 汇总（每轮明细 + 统计量 + 环境元数据 + 数据集来源/参数）。<br>`datasetSource` 形如 `documents · vision_mix_50=50,mlperf_llm=0`，可据此事后还原数据集档位 |
| `telemetry_<uuid>.jsonl` | 逐条明细，每行一个 sample（聚合口径可事后调整，但原始明细丢失后无法重建） |

取回设备：

```bash
xcrun devicectl device copy from --device $UDID \
  --domain-type appDataContainer --domain-identifier $BID \
  --source Documents/benchmark_results --destination /tmp/bench_results
```

### 必须知道的口径

1. **`perf app` 的 t/s 不含步间隔**：`decode_ms` 只累加 decode 循环内部时间，
   `Task.sleep` 让出（bench 3 ms / 对话 10 ms）不计入。bench 默认配置下，
   墙钟吞吐约为报告值的 **0.84**（实测 203 token：报告 17.5 t/s，墙钟 14.9 t/s）。
2. **汇总里的 `decode_tps` 是「每轮 t/s 的算术平均」**，而非「总 token ÷ 总时间」。
   等长轮次下等价；有离群轮会被拉偏。
3. **`TTFT` 是端到端**（图编码 + 预热 + prep + prefill），而 `prefill_tps` 是**纯 llama prefill**，
   两者不能互相印证。
4. **长度不同不可比**：输出越长、专家搬运越多。跨 case/跨设备比较要么固定 `-benchTokens`，
   要么只比同一 `-benchMaxTokens` 下的结果。
5. **`gpuTimeNs` 在部分 iPhone 上恒为 0**，此时 GPU 时长门禁失效，改用 CPU cycles 做相对比较。

---

## 7. 常见问题与排查

| 现象 | 原因 / 处理 |
|---|---|
| 只生成 1 个 token | 旧版本把 `decodeTokenLimit` 钳到下限 1 的缺陷，已修复；`-benchMaxTokens 0` 表示不设上限 |
| `[BENCH] error: 过滤后没有可用 case` | `-benchCases` 的 key 不在所选数据集里（vision_mix_50 是 3001~3050、mlperf 是 1001~2033） |
| 跑批吞吐低于日常对话 | 先确认 `-genSleepMs`（bench 默认已改为 3 ms）。旧版本固定为 10 ms，会使 GPU 降频一档，吞吐低约 22% |
| 逐块/逐轮变慢 | 热节流。检查 `thermal=` 与每轮 `decode_tps`；可增加 `-benchCooldown`、减少轮数或延长 `-benchIdleSec` |
| 纯文本数据集开启预热后进程被系统终止 | 历史问题：纯文本预热会触发 llama_context 重建并被 SIGKILL。现版本改用 `warmup.png` 造预热 case，缺失时直接跳过预热 |
| 换设备后提示图片缺失 | 数据集未铺开：删除 `Documents/benchmark/<track>/` 后重启 App，或查看 `[BENCH] dataset=… install=…` 行 |
| 结果中的输出文本无意义 | 使用了 `-moeSkipRead`（B 档）。设计如此：算力路径一致，但内容不可用 |

---

## 8. 相关文档

| 文档 | 内容 |
|---|---|
| `scripts/pwrbench/README.md` | 整机功率测量（A/B 档、配对交替、`pymobiledevice3` 采样） |
| `MiniCPM-V-demo/Resources/Benchmark/*/README.md` | 两条数据集的来源、构造方式、许可 |
