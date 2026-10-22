//
//  BenchmarkRunner.swift
//  MiniCPM-V-demo
//
//  批量基准测试的执行器：串行、单流（single-stream）地跑完数据集里每一条 case。
//
//  为什么串行：MLPerf Mobile 的 LLM 项只有 SingleStream 一种跑法
//  （`mobile_inference_rules.adoc:160-161`：「LoadGen sends next query as soon as
//  SUT completes the previous query」），且我们的引擎是单状态机
//  （mtmd_context 一次只能推进一个回合），并发会读到错乱的 n_past。
//
//  每个 case 的隔离策略（**必须写进报告**，否则测的是「命中后的速度」）：
//  - KV cache 每个 case 前清空（clearKVCacheForNewTurn）
//  - 固定输出 token 数（decodeTokenLimit），不等 EOG
//  - 温度固定为 0（贪心），由调用方在初始化参数里设置
//  对应 MLPerf 规则 `:290-291` —— 禁止缓存任何中间结果。
//

import Foundation
import UIKit

// MARK: - 运行配置

public struct BenchmarkRunConfig {

    /// 每个 case 重复几轮。
    ///
    /// 统计上有个明确的取舍：**跨 case 的方差通常远大于同 case 重复间的方差**，
    /// 所以宁可「多 case × 少重复」也不要「少 case × 多重复」。
    /// 重复轮数主要服务于两件事：估计可复现性（同一 case 轮间的离散度）、
    /// 以及降低均值的不确定度（标准误 ∝ 1/√n）。
    public let repetitions: Int

    /// 固定输出 token 数。**必须固定**，否则输出长度不同 → decode 搬运量不同 →
    /// 跨 case 的 t/s 放在一起比是错的。
    public let decodeTokenLimit: Int

    /// 选图后是否走预热。App 的真实路径有这一步，默认跟真实路径一致。
    public let prewarmAfterImage: Bool

    /// 是否在正式跑批前做一次**短预热**。
    ///
    /// 用一句「你好」跑 10 个 token，跑完丢弃。
    ///
    /// 为什么不沿用「丢掉第一轮完整 case」：
    /// 那要多跑一整轮（12 条 × 20 s ≈ 4 分钟），而预热要达到的目的 ——
    /// 专家页进页缓存、GPU 频率爬升、mmproj 完成首次 forward ——
    /// 这 10 个 token 就够了。实测那次对照里，预热轮的 TTFT 和计量轮只差 0.1%，
    /// 说明一整轮预热本来就是浪费。
    public let warmupEnabled: Bool

    /// 预热用的固定提示词。
    public static let warmupPrompt = "你好"
    /// 预热输出步数。只求把管线走热，不求内容。
    public static let warmupTokens = 10

    /// 轮间冷却秒数（0 = 不冷却）。
    ///
    /// 两个作用：
    /// 1. **防过热**：连续满载会让 SoC 降频，跑得越久越慢，把热漂移混进结果；
    /// 2. **让每轮起点相近**：每轮开始前回到相近的热状态，轮间才可比。
    /// 冷却期间不跑任何推理，只等待。
    public let cooldownSec: Double

    /// 每条 case 前是否清 KV（默认清）。
    ///
    /// 日常对话路径**从来不调** `clearKVCacheForNewTurn()`，而 bench 每轮都调。
    /// 排查「同一条 case、bench 比对话慢 10%」时用它做对照。
    public let resetKVBeforeCase: Bool

    /// `decodeTokenLimit` 是「上限」还是「固定步数」。
    /// true = 允许模型撞 EOG 提前停（功耗测量用）；false = 历史行为，忽略 EOG。
    public let stopAtEOG: Bool

    public init(repetitions: Int,
                decodeTokenLimit: Int,
                prewarmAfterImage: Bool = true,
                warmupEnabled: Bool = false,
                cooldownSec: Double = 0,
                resetKVBeforeCase: Bool = true,
                stopAtEOG: Bool = false) {
        self.repetitions = repetitions
        self.decodeTokenLimit = decodeTokenLimit
        self.prewarmAfterImage = prewarmAfterImage
        self.warmupEnabled = warmupEnabled
        self.cooldownSec = max(0, cooldownSec)
        self.resetKVBeforeCase = resetKVBeforeCase
        self.stopAtEOG = stopAtEOG
    }

    /// 实际要执行的 sample 总数（含那条短预热）
    public func totalSamples(caseCount: Int) -> Int {
        caseCount * repetitions + (warmupEnabled ? 1 : 0)
    }

    /// 计入统计的 sample 数
    public func measuredSamples(caseCount: Int) -> Int { caseCount * repetitions }
}

// MARK: - 执行器

@MainActor
public final class BenchmarkRunner: ObservableObject {

    public enum Phase: String {
        case idle
        case running
        case finished
        case cancelled
        case failed
    }

    // MARK: 对外可观察状态

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var progressText: String = ""
    @Published public private(set) var doneCount: Int = 0
    @Published public private(set) var totalCount: Int = 0
    @Published public private(set) var lastResult: BenchmarkRunResult?
    @Published public private(set) var failureMessage: String?

    /// 本轮跑出来的全部 sample（明细）。导出时会写成 telemetry jsonl。
    public private(set) var samples: [BenchmarkSample] = []

    private var isCancelled = false

    // MARK: - 主入口

    /// 串行跑完整批。
    ///
    /// - Important: 调用前必须已加载好模型，且温度已设为 0（贪心）。
    ///   温度不固定则结果不可复现，直接违反 `mobile_inference_rules.adoc:134`。
    public func run(cases: [BenchmarkCase],
                    config: BenchmarkRunConfig,
                    example: MTMDWrapperExample) async {
        guard !cases.isEmpty else {
            fail("数据集为空，先生成示例数据集或放入 cases.jsonl")
            return
        }
        guard example.multiModelLoadingSuccess else {
            fail("模型未加载完成")
            return
        }

        // 采样随机性是 MLPerf 明文不允许的非确定性之一
        // （`mobile_inference_rules.adoc:104-117` 只认浮点序 / 输入遍历 / 舍入）。
        //
        // 现在温度由代码单点决定（`MTMDParams.temperature` 默认 0.0 = 贪心，
        // `MB_TEMP` 环境变量覆盖已删除），正常情况下这里恒过。
        // 仍保留检查：万一日后有人把默认值改回去，这里会直接拦下，
        // 而不是让你跑完一整批才发现数据不可复现。
        let effectiveTemp = Self.effectiveTemperature(example: example)
        if effectiveTemp != 0 {
            fail("采样温度为 \(effectiveTemp)，跑批必须为 0（贪心）。" +
                 "请把 MTMDParams.temperature 的默认值改回 0.0 并重新编译。")
            return
        }

        phase = .running
        isCancelled = false
        samples = []
        lastResult = nil
        failureMessage = nil

        // 全程保持屏幕常亮。
        //
        // 这不是「用户体验」优化，是**测量正确性**要求：息屏会让 App 进后台被系统挂起，
        // 跑批静默中断，而进程还活着 —— 表现就是「日志不动了、界面停在某一步」，
        // 很容易被误判成死锁。长跑（十几分钟）必须挡住自动锁屏。
        // 注意：跑批模式（`-bench`）下这里**不能**在 defer 里恢复成 false。
        // 功耗测量要靠 `-benchStay` 在同一进程里接着测「待机基线」，
        // 一旦息屏，待机功率会从 ~2.3 W 掉到 ~0.8 W（实测 iPhone），
        // 「纯计算 = B − 待机」会被凭空抬高 1.5 W 左右。
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = BenchmarkLaunchCommand.isRequested }

        let runId = UUID().uuidString
        let wallStart = Date()
        totalCount = config.totalSamples(caseCount: cases.count)
        doneCount = 0

        // 固定输出长度：复用 App 已有的 decodeTokenLimit（MTMDWrapper.swift:43）。
        example.mtmdWrapper.decodeTokenLimit = config.decodeTokenLimit
        example.mtmdWrapper.stopAtEOG = config.stopAtEOG

        // 与 App 保持一致意味着：每个图像回合都会走一遍
        //   prefill_image（eager 编码）→ prewarm（**卸载视觉塔**）→ prefill_text（**重新
        //   mb_ensure_vision 重载 mmproj**）→ eval_prefill → 再卸载。
        // 也就是说 mmproj 的重载耗时落在 prep_ms 里，每个 case 都要付一次。
        // 这是 App 手工测时的真实行为，所以默认保留；`MB_MOE_UNLOAD_MMPROJ=0` 可关掉，
        // 但那测的就不是 App 的行为了，必须与本报告区分开。

        // 不做"跑够 N 条就停"或"超时中止"之类的判定 —— 那属于某个具体基准的规则。
        // 这里只负责把「指定的 case × 指定的轮数」老老实实跑完，
        // 有多少样本就报多少样本，统计量如实呈现（含离散度与置信区间）。
        // ── 短预热 ──
        //
        // 用**第一条 case 的图 + 一句固定短提示**跑 10 个 token，跑完丢弃。
        //
        // ⚠️ 这里必须带图，不能纯文本。踩过的坑：纯文本 "你好" 会让引擎判定为
        // 「vision first prefill 但 has_image=0, n_tokens=0」，进而触发
        // `adaptive ubatch: switch 1024 -> 128` **重建整个 llama_context**；
        // 在释放旧 context 的那一刻进程被系统以 signal 9 杀掉（实测必现）。
        // 正常 App 流程永远是先图后文，走不到这条路径 —— 为了预热人为造出来不值得。
        // 复用 runOne 的完整链路（图编码 → 预热 → 文本 → prefill → decode）即可绕开。
        // 预热图的选择：
        //   1) 优先借数据集里第一条带图 case（图文 track 自然满足）；
        //   2) 纯文本 track（`mlperf_llm`）没有带图 case，此时**不能**退化到纯文本
        //      （见上一条注释，会把 llama_context 重建掉、进程被 signal 9 杀掉），
        //      改为借 track 目录里的 `warmup.png` 造一条临时 case；
        //   3) 两者都没有 → 本次跳过预热（宁可少走一遍管线，也不能崩）。
        var warmupCase: BenchmarkCase? = cases.first(where: { $0.image != nil })
        if warmupCase == nil {
            let probe = BenchmarkCaseStore.imageURL("warmup.png")
            if FileManager.default.fileExists(atPath: probe.path) {
                warmupCase = BenchmarkCase(key: -1,
                                           image: "warmup.png",
                                           text: BenchmarkRunConfig.warmupPrompt)
            } else {
                print("[BENCH] 无带图 case 也无 warmup.png，跳过预热（避免纯文本预热的 SIGKILL）")
            }
        }

        if config.warmupEnabled, let wc = warmupCase {
            progressText = "预热中（固定图 + \(BenchmarkRunConfig.warmupTokens) token）…"
            let savedLimit = example.mtmdWrapper.decodeTokenLimit
            example.mtmdWrapper.decodeTokenLimit = BenchmarkRunConfig.warmupTokens
            let warmCase = BenchmarkCase(key: -1,
                                         image: wc.image,
                                         text: BenchmarkRunConfig.warmupPrompt)
            let warm = await runOne(case: warmCase,
                                    config: config,
                                    repetition: -1,
                                    isWarmup: true,
                                    orderInPass: -1,
                                    runId: runId,
                                    example: example)
            // 无论成功失败都恢复正式步数，否则后面所有 case 都只出 10 个 token
            example.mtmdWrapper.decodeTokenLimit = savedLimit
            samples.append(warm)
            doneCount += 1
        }

        // ── 正式轮次：拉丁方轮转 ──
        // MoE 的专家 slot 缓存按**进程存活期**存在，无法逐 case 清空（见 cachePolicy）。
        // 固定顺序会让同一批 case 每次都处在相同位次，位次带来的冷热差异就会
        // 伪装成 case 间差异。每轮把起始 case 错开一位，效应被摊平。
        outerLoop: for pass in 0..<config.repetitions {
            if pass > 0, config.cooldownSec > 0 {
                let waited = Int(Date().timeIntervalSince(wallStart))
                progressText = "第 \(pass + 1)/\(config.repetitions) 轮前冷却 \(Int(config.cooldownSec))s"
                    + "（已跑 \(waited)s）"
                try? await Task.sleep(nanoseconds: UInt64(config.cooldownSec * 1_000_000_000))
            }

            let ordered = cases.rotated(by: pass)

            for (pos, c) in ordered.enumerated() {
                if isCancelled { break outerLoop }

                let sample = await runOne(case: c,
                                          config: config,
                                          repetition: pass,
                                          isWarmup: false,
                                          orderInPass: pos,
                                          runId: runId,
                                          example: example)
                samples.append(sample)
                doneCount += 1
                progressText = "第 \(pass + 1)/\(config.repetitions) 轮"
                    + " · #\(c.key)（第 \(pos + 1) 位）· \(doneCount)/\(totalCount)"
            }
        }

        let wallSec = Date().timeIntervalSince(wallStart)

        if isCancelled {
            phase = .cancelled
            progressText = "已取消（\(doneCount)/\(totalCount)）"
            return
        }

        do {
            let result = BenchmarkRunResult.build(runId: runId,
                                                  config: config,
                                                  samples: samples,
                                                  temperature: effectiveTemp,
                                                  measuredDurationSec: wallSec)
            try BenchmarkResultStore.save(result: result, samples: samples)
            lastResult = result
            phase = .finished
            progressText = "完成：\(doneCount) 条（有效 \(result.stats.sampleCount) 条）"
        } catch {
            fail("结果落盘失败：\(error.localizedDescription)")
        }
    }

    public func cancel() {
        isCancelled = true
    }

    /// 采样温度。
    ///
    /// 现在桥接层**只认** `params.temperature`（`MB_TEMP` 环境变量覆盖已删除，
    /// 见 `MBMtmd.mm` 多模态/纯文本两条 init 路径），所以这里读到的就是实际生效值，
    /// 不再有「显示 0.7 但实际贪心」那种错位。
    static func effectiveTemperature(example: MTMDWrapperExample) -> Float {
        example.mtmdWrapper.params?.temperature ?? 0.0
    }

    // MARK: - 单条 case

    private func runOne(case c: BenchmarkCase,
                  config: BenchmarkRunConfig,
                  repetition: Int,
                  isWarmup: Bool,
                  orderInPass: Int,
                  runId: String,
                        example: MTMDWrapperExample) async -> BenchmarkSample {

        let thermalBefore = Self.thermalString()
        let batteryBefore = Self.batteryLevel()
        let batteryStateBefore = Self.batteryStateString()
        // 任务 2：能量/磁盘 I/O/GPU 时长采样（case 前）
        let energyBefore = BenchmarkEnergyProbe.take()
        let t0 = Date()
        var errorMsg: String?

        // ① 每个 case 从干净 KV 开始 —— 不清则上一条的上下文会改变 prefill 长度。
        if config.resetKVBeforeCase {
            example.clearKVCacheForNewTurn()
        }

        // ②③ 逐轮 prefill。单轮 case 被合成为一条 user 消息，两种形态走同一条路径。
        //
        // 口径 B：各轮 prefill 由引擎侧累加、decode 只算末轮，所以 prefill_ms /
        // prefill_tokens 是「整段会话」口径，见 docs/BENCHMARK.md §5.4。
        let turns = c.turns
        if turns.last?.role != .user {
            // 以 assistant 收尾的 case 不会写入 assistant 头，等于一段没有起点的续写，测了没意义。
            errorMsg = "末轮必须是 user（case \(c.key)）"
        }
        var prewarmMs: Double = 0
        var turnWallMs: [Double] = []
        var imageTurns = 0
        // 分阶段能量：无图时它就是「KV 清空后」的基线
        var energyAfterImage = BenchmarkEnergyProbe.take()

        // 工具定义必须作为第一个 system 段写入（n_past == 0），模型才知道有哪些函数可调。
        // turnWallMs 下标与消息一一对应，所以这一段不占位（它的耗时落在 prefill 的 prep 里）。
        if let toolsJSON = c.toolsJSON, errorMsg == nil {
            if turns.first?.role == .system {
                errorMsg = "tools 与独立 system 消息同时出现暂不支持（case \(c.key)）"
            } else {
                let ok = await example.addTextInBackground(toolsJSON, role: "tools")
                if !ok { errorMsg = "tools 段 prefill 失败" }
            }
        }

        for (index, turn) in turns.enumerated() where errorMsg == nil {
            // 预热单独计时：它不只是"重建 ubatch"，还会真从 SSD 读专家做预热。
            // 首轮实测 wall-clock 有约 3.4 s/条对不上账，怀疑主要就在这里 ——
            // 引擎侧没有任何计时覆盖它（perf_image_ms 只覆盖 eager 编码）。
            if let image = turn.image {
                imageTurns += 1
                if imageTurns > 1 {
                    errorMsg = "只有第一轮可以带图（case \(c.key)）"
                    break
                }
                let path = BenchmarkCaseStore.imageURL(image).path
                let ok = await example.addImageInBackground(path)
                if !ok {
                    errorMsg = "图片 prefill 失败：\(image)"
                    break
                }
                if config.prewarmAfterImage {
                    let t = Date()
                    await example.prewarmAfterImageInBackground()
                    prewarmMs = Date().timeIntervalSince(t) * 1000.0
                }
                // 分阶段能量：图片处理 + 专家预热这一段结束
                energyAfterImage = BenchmarkEnergyProbe.take()
            }

            guard let role = turn.role.prefillRole(isLast: index == turns.count - 1) else {
                errorMsg = "tool 消息暂不支持（C 层无 tool 模板，case \(c.key)）"
                continue
            }

            let t = Date()
            let ok = await example.addTextInBackground(turn.text, role: role)
            turnWallMs.append(Date().timeIntervalSince(t) * 1000.0)
            if !ok { errorMsg = "文本 prefill 失败（role=\(role)）" }
        }

        // 分阶段能量：prefill 结束（此时还没开始解码）
        let energyAfterPrefill = BenchmarkEnergyProbe.take()

        // ④ 生成（固定步数，不等 EOG）
        if errorMsg == nil {
            await example.startGeneration()
            let settled = await waitForSettled(example: example, timeoutSec: Self.perCaseTimeoutSec)
            if !settled { errorMsg = "生成超时（>\(Int(Self.perCaseTimeoutSec))s）" }
        }

        let wallMs = Date().timeIntervalSince(t0) * 1000.0
        let p = example.mtmdWrapper.lastPerf

        // 任务 2 V1：能量采样（case 后）+ 诊断输出。
        //
        // V1 的目的只有一个：确认 `ri_energy_nj` / `ri_diskio_bytesread` / `gpu_time`
        // 在 iOS 17.7 上**真的非零递增**。所以这里原始值与增量都打出来，
        // 等 V2 定下口径后再收进 BenchmarkSample 的字段里。
        let energyAfter = BenchmarkEnergyProbe.take()

        NSLog("%@", BenchmarkEnergyProbe.debugLine("t0      ", energyBefore))
        NSLog("%@", BenchmarkEnergyProbe.debugPhaseLine("图像+预热",
                                                        energyBefore, energyAfterImage))
        NSLog("%@", BenchmarkEnergyProbe.debugPhaseLine("prefill ",
                                                        energyAfterImage, energyAfterPrefill))
        NSLog("%@", BenchmarkEnergyProbe.debugPhaseLine("decode  ",
                                                        energyAfterPrefill, energyAfter))
        NSLog("%@", BenchmarkEnergyProbe.debugPhaseLine("整条case",
                                                        energyBefore, energyAfter))

        return BenchmarkSample(
            runId: runId,
            repetition: repetition,
            isWarmup: isWarmup,
            orderInPass: orderInPass,
            caseKey: c.key,
            promptUTF8Length: turns.reduce(0) { $0 + $1.text.utf8.count },
            startISO: Self.iso8601(t0),
            wallMs: wallMs,
            prefillTokens: Int(p.prefill_tokens),
            prefillMs: p.prefill_ms,
            decodeTokens: Int(p.decode_tokens),
            decodeMs: p.decode_ms,
            prepMs: p.prep_ms,
            imageTokens: Int(p.image_tokens),
            imageEncodeMs: p.image_encode_ms,
            prewarmMs: prewarmMs,
            moeKPrefill: Int(p.moe_k_prefill),
            moeKDecode: Int(p.moe_k_decode),
            thermalBefore: thermalBefore,
            thermalAfter: Self.thermalString(),
            batteryBefore: batteryBefore,
            batteryAfter: Self.batteryLevel(),
            batteryStateBefore: batteryStateBefore,
            batteryStateAfter: Self.batteryStateString(),
            residentMemoryMiB: Self.residentMemoryMiB(),
            error: errorMsg,
            turnWallMs: turnWallMs
        )
    }

    /// 单条 case 的超时上限（秒）。给足，正常一条远小于这个值。
    private static let perCaseTimeoutSec: Double = 180

    /// 等生成进入终态。
    ///
    /// 用轮询而不是 Combine 的 AsyncPublisher：`startGeneration()` 是「建 Task 就返回」，
    /// 而 Publisher.values 会把进入时的当前值先吐一次（此时可能已是上一轮的 .completed），
    /// 容易误判成"已结束"。轮询虽然笨，但没有这个坑，20 ms 的间隔相对单条秒级耗时可忽略。
    private func waitForSettled(example: MTMDWrapperExample, timeoutSec: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            switch example.mtmdWrapper.generationState {
            case .completed, .cancelled:
                return true
            case .failed:
                return true
            case .idle, .generating:
                break
            }
            if isCancelled { return false }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
        return false
    }

    private func fail(_ msg: String) {
        failureMessage = msg
        phase = .failed
        progressText = msg
    }

    // MARK: - 环境采样

    private static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func batteryLevel() -> Float {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryLevel // 未开启 / 未知时为 -1
    }

    private static func batteryStateString() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .unknown:   return "unknown"
        case .unplugged: return "unplugged"
        case .charging:  return "charging"
        case .full:      return "full"
        @unknown default: return "unknown"
        }
    }

    /// 常驻内存（MiB）。用 phys_footprint，比 resident_size 更贴近真实占用。
    private static func residentMemoryMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - 轮次交错辅助

extension Array {

    /// 循环左移 n 位，用于拉丁方轮转。
    ///
    /// 每轮把起始 case 往后错一位，使每条 case 在各轮中占据不同位次：
    ///   第 0 轮 1,2,3,4
    ///   第 1 轮 2,3,4,1
    ///   第 2 轮 3,4,1,2
    /// 这样「位次带来的冷热差异」会被均摊到所有 case 上，而不是固定压在
    /// 排在前面的那几条身上。MoE 专家缓存无法逐 case 清空时，这是最省事的对冲。
    func rotated(by n: Int) -> [Element] {
        guard count > 1 else { return self }
        let k = ((n % count) + count) % count
        return Array(self[k...]) + Array(self[..<k])
    }
}
