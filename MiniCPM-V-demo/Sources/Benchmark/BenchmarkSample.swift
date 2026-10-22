//
//  BenchmarkSample.swift
//  MiniCPM-V-demo
//
//  一条 sample = 一次「喂一个 case + 出 N 个 token」的完整记录。
//
//  设计要点：
//  1. **原样保存引擎给的每个字段**，不在这里做统计 —— 原始明细落盘后，
//     统计口径（mean / 分位 / 剔除离群）可以事后换，历史数据不会作废。
//  2. TTFT 给**两个口径**：引擎内部口径（只 prefill）与端到端口径（含预处理）。
//     MLPerf 规则 `mobile_inference_rules.adoc:377-378` 明确要求前处理计入 wall-clock，
//     而我们引擎把 prep 与 prefill 分开记（便于内部分解），所以两边都要留。
//  3. 热状态与电量**前后各记一次**，否则无法判断某次跑慢是因为热节流还是因为 case 本身。
//

import Foundation

/// 单次运行的完整记录。落盘为 telemetry jsonl 的一行。
public struct BenchmarkSample: Codable {

    // MARK: - 归属

    public let runId: String
    /// 轮次序号。**含预热轮** —— 预热轮也占一个序号，方便对齐原始日志。
    public let repetition: Int
    /// 本条是否属于预热轮。
    ///
    /// 预热轮照样完整跑、照样落盘（保留证据），但**不进统计**：
    /// 第一次进 case 时专家页不在缓存里、GPU 频率还没爬升，
    /// 那一条天生偏慢，混进均值会把它拉高，还会被离群检测误判。
    public let isWarmup: Bool
    /// 本条在该轮内的实际执行位次（轮转后的位置）。
    ///
    /// 记下来是为了事后能验证「交错是否真的生效」，
    /// 以及在顺序效应显著时把位次当协变量做校正。
    public let orderInPass: Int
    public let caseKey: Int

    /// 提示词的 UTF-8 字节数。
    ///
    /// 内置数据集的 12 条提示词长度差别很大（最短「判断图中的月相」，
    /// 最长那条带方位与时间推断的背景描述）。prefill token 数因此不同，
    /// 跨 case 比 TTFT 时会混进这个变量 —— 记下来是为了事后能按它分组或协变校正，
    /// 而不是假装不存在。真要做严格对比，应另配一套等长提示词的数据集。
    public let promptUTF8Length: Int

    // MARK: - 时间

    /// ISO8601 UTC，例 `2026-10-18T03:54:54.687Z`
    public let startISO: String
    /// 本条端到端墙钟（含预处理 + prefill + decode），毫秒
    public let wallMs: Double

    // MARK: - 引擎计时（原样来自 mb_mtmd_perf）

    public let prefillTokens: Int
    public let prefillMs: Double
    public let decodeTokens: Int
    public let decodeMs: Double
    /// 送回合的准备耗时（mmproj reload / 图片解码 / tokenize），在 prefill_ms 之外
    public let prepMs: Double
    public let imageTokens: Int
    public let imageEncodeMs: Double
    /// 选图后的预热耗时（`prewarm_after_image`）。
    /// 它不只是"重建 ubatch"，还会真读 SSD 上的专家做预热 —— 实测可达秒级，
    /// 之前没有计时覆盖它，导致 wall-clock 对不上账。
    public let prewarmMs: Double
    public let moeKPrefill: Int
    public let moeKDecode: Int

    // MARK: - 派生指标

    /// 引擎口径 TTFT：只有 prefill
    public let ttftEngineMs: Double
    /// 端到端 TTFT：**图编码 + 预热 + prep + prefill**。
    ///
    /// 对外必须用这个。三笔前处理都在 wall-clock 里，缺任何一笔都会低估：
    ///   - `imageEncodeMs`：eager 图像编码，发生在回合**外**，引擎刻意没算进 prefill_ms
    ///   - `prewarmMs`：`prewarm_after_image`，会真的从 SSD 读专家，实测可达秒级
    ///   - `prepMs`：mmproj reload + 图片解码 + tokenize
    /// MLPerf `mobile_inference_rules.adoc:377-378` 要求前处理计入 wall-clock。
    public let ttftEndToEndMs: Double
    /// wall 里没有归入任何分项的部分，毫秒。
    ///
    /// 实测约等于 `10 ms × decodeTokens` —— 来自生成循环里每输出一个 token 就
    /// `Task.sleep(10ms)` 让出主线程（`MTMDWrapper.swift:629`）。
    /// 它是**给 UI 的让步**，不是计算开销，但确实计入 wall。
    /// 单独列出来，否则看报告的人会以为存在 3~4 秒的「神秘开销」。
    public let unaccountedMs: Double
    /// TPOT：平均每个输出 token 的耗时
    public let tpotMs: Double?
    public let prefillTokensPerSec: Double?
    public let decodeTokensPerSec: Double?

    // MARK: - 环境与状态（前后各一次）

    public let thermalBefore: String
    public let thermalAfter: String
    public let batteryBefore: Float
    public let batteryAfter: Float
    public let batteryStateBefore: String
    public let batteryStateAfter: String
    /// 本条跑完时的常驻内存，MiB
    public let residentMemoryMiB: Double

    /// 每一轮 prefill 的墙钟耗时（ms），下标 = 消息序号；单轮 case 长度为 1。
    ///
    /// 主指标是引擎侧累计值（口径 B），这一项只用于事后切出「末轮单独」或「逐轮」视图。
    /// 墙钟含线程调度噪声，不要当主指标用。
    public let turnWallMs: [Double]?

    // MARK: - 异常

    /// 本条是否跑失败；非 nil 即失败原因，该条不进统计。
    public let error: String?

    /// 本条是否有效（无错误、且有输出 token）
    public var isValid: Bool { error == nil }

    public init(runId: String,
                repetition: Int,
                isWarmup: Bool,
                orderInPass: Int,
                caseKey: Int,
                promptUTF8Length: Int,
                startISO: String,
                wallMs: Double,
                prefillTokens: Int,
                prefillMs: Double,
                decodeTokens: Int,
                decodeMs: Double,
                prepMs: Double,
                imageTokens: Int,
                imageEncodeMs: Double,
                prewarmMs: Double,
                moeKPrefill: Int,
                moeKDecode: Int,
                thermalBefore: String,
                thermalAfter: String,
                batteryBefore: Float,
                batteryAfter: Float,
                batteryStateBefore: String,
                batteryStateAfter: String,
                residentMemoryMiB: Double,
                error: String?,
                turnWallMs: [Double]? = nil) {
        self.runId = runId
        self.repetition = repetition
        self.isWarmup = isWarmup
        self.orderInPass = orderInPass
        self.caseKey = caseKey
        self.promptUTF8Length = promptUTF8Length
        self.startISO = startISO
        self.wallMs = wallMs
        self.prefillTokens = prefillTokens
        self.prefillMs = prefillMs
        self.decodeTokens = decodeTokens
        self.decodeMs = decodeMs
        self.prepMs = prepMs
        self.imageTokens = imageTokens
        self.imageEncodeMs = imageEncodeMs
        self.prewarmMs = prewarmMs
        self.moeKPrefill = moeKPrefill
        self.moeKDecode = moeKDecode
        self.thermalBefore = thermalBefore
        self.thermalAfter = thermalAfter
        self.batteryBefore = batteryBefore
        self.batteryAfter = batteryAfter
        self.batteryStateBefore = batteryStateBefore
        self.batteryStateAfter = batteryStateAfter
        self.residentMemoryMiB = residentMemoryMiB
        self.error = error
        self.turnWallMs = turnWallMs

        self.unaccountedMs = wallMs - (imageEncodeMs + prewarmMs + prepMs + prefillMs + decodeMs)
        self.ttftEngineMs = prefillMs
        // 端到端 = 图像 eager 编码 + 预热 + 回合内 prep + prefill。
        // 前两笔都发生在回合外，引擎刻意没算进 prefill_ms，这里必须补回来，
        // 否则 TTFT 会系统性低估（实测低估 37%）。
        self.ttftEndToEndMs = imageEncodeMs + prewarmMs + prepMs + prefillMs
        self.tpotMs = decodeTokens > 0 ? decodeMs / Double(decodeTokens) : nil

        func rate(_ n: Int, _ ms: Double) -> Double? {
            guard n > 0, ms > 0 else { return nil }
            return Double(n) / (ms / 1000.0)
        }
        self.prefillTokensPerSec = rate(prefillTokens, prefillMs)
        self.decodeTokensPerSec = rate(decodeTokens, decodeMs)
    }
}
