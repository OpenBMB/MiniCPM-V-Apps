//
//  BenchmarkResult.swift
//  MiniCPM-V-demo
//
//  一次跑批的结果：统计量 + 分项分解 + 逐 case 明细，外加落盘。
//
//  ⚠️ 这里**不做档位划分、不做合格/不合格判定**。
//  那是某个具体基准（如 MLPerf）针对特定模型定的规则，不是统计本身。
//  我们只学它两件事：
//    - 怎么把一组观测算成能对外的一组数（见 BenchmarkStatistics.swift）
//    - 结果以什么形式、给出哪些具体数字（见本文件的 Stats / Breakdown / PerCase）
//
//  结构仍参考 MLPerf Mobile `docs/result-spec.md` 的 meta / environment_info /
//  build_info 三段 —— 那部分是「结果要自证来源」的通用做法，值得保留。
//

import Foundation

// MARK: - 分项耗时（单条平均）

/// 单条 case 的耗时分解（各项的均值，毫秒）。
///
/// 为什么要单独给：聚合一个 TTFT 说明不了慢在哪。对我们这个系统
/// （图像编码 / MoE 专家预热 / mmproj reload / prefill / decode 各走各的路）
/// 没有分解就无法归因，也无法支撑「GPU 大头还是 SSD 大头」这类判断。
public struct BenchmarkBreakdown: Codable {
    /// eager 图像编码（回合外）
    public let imageEncodeMs: Double
    /// 选图后预热（会真读 SSD 上的专家）
    public let prewarmMs: Double
    /// 回合内准备：mmproj reload + 图片解码 + tokenize
    public let prepMs: Double
    public let prefillMs: Double
    public let decodeMs: Double
    /// 端到端墙钟
    public let wallMs: Double
    /// wall 中没有归入上面任何一项的部分（≈ 10 ms × decode token，生成循环让出主线程的让步）
    public let unaccountedMs: Double
}

// MARK: - prefill 的长度特性

/// prefill 耗时对 token 数的线性关系：`t = fixedMs + msPerToken · tokens`。
///
/// 为什么不报「prefill tok/s」：那是个**比值**，而 prefill 是**仿射**的（有固定开销）。
/// 实测 M4（12 case × 2 轮）：
///   `t = 2790 ms + 4.706 ms/token`，R² ≈ 0.99
/// 也就是说 96 token 的短 prompt 只有 32 tok/s，643 token 的长 prompt 有 115 tok/s
/// —— 差 3.6 倍，全部来自那 2.79 s 固定开销，与「吞吐能力」无关。
/// 把比值当指标会让短 prompt 看起来「慢」，还会被离群检测误判成异常点。
public struct BenchmarkPrefillFit: Codable, Equatable {
    /// 与长度无关的固定开销（ms）
    public let fixedMs: Double
    /// 每 token 的边际耗时（ms）
    public let msPerToken: Double
    /// 边际吞吐 = 1000 / msPerToken
    public let marginalTokensPerSec: Double
    /// 拟合优度
    public let rSquared: Double
    public let n: Int
}

// MARK: - 逐 case 明细

/// 每个 case 各自的统计。
///
/// 跨 case 的方差通常远大于同 case 重复间的方差 —— 不按 case 拆开看，
/// 一句「均值 7 s」会掩盖「这张图 15 s、那张图 5 s」这种真实差异。
public struct BenchmarkCaseSummary: Codable {
    public let caseKey: Int
    public let n: Int
    public let meanTTFTMs: Double
    public let medianTTFTMs: Double
    public let meanTPOTMs: Double
    public let meanPrefillTokens: Double
    public let meanImageTokens: Double
    /// 提示词 UTF-8 字节数，用于判断 prefill token 差异有多少来自文本长度
    public let promptUTF8Length: Int
}

// MARK: - 统计量汇总

public struct BenchmarkStats: Codable {

    /// 有效样本数（失败的不计）
    /// 计入统计的样本数（不含预热轮、不含失败）
    public let sampleCount: Int
    /// 本轮实际执行的总样本数（含预热轮、含失败）
    public let requestedSampleCount: Int
    /// 被丢弃的预热样本数
    public let warmupDiscarded: Int
    public let measuredDurationSec: Double

    // 主指标：MLPerf 对 LLM 用 mean（mobile_inference_rules.adoc:153-161），
    // 每个都带 95% CI、median、离散度、离群点情况。
    public let ttft: BenchmarkDescriptive
    public let tpot: BenchmarkDescriptive
    public let prefillTokensPerSec: BenchmarkDescriptive
    public let decodeTokensPerSec: BenchmarkDescriptive

    /// prefill 的**长度特性**（固定开销 + 边际速率）。见 `BenchmarkPrefillFit`。
    /// 样本不足（或 token 数全相同）时为 nil。
    public let prefillFit: BenchmarkPrefillFit?

    /// 实际输出 token 数的分布。
    ///
    /// ⚠️ `decodeTokenLimit` 是**上限不是定长**：生成循环撞到 EOG 就提前结束，
    /// 不等上限。实测 24 条里只有 12 条跑到 256，其余在 53~222 就停了。
    /// 这不影响 TPOT / decode t/s（它们按 token 归一），
    /// 但会让**每条的 wall 时间与能耗不可比** —— 必须按这个分布去解读。
    public let decodeTokenLength: BenchmarkDescriptive

    /// 单条耗时分解（各项均值）
    public let breakdown: BenchmarkBreakdown

    /// 逐 case 明细
    public let perCase: [BenchmarkCaseSummary]

    /// 可复现性：同一个 case 跨轮次的相对离散度（各 case 的 CoV 取中位数）。
    /// 越接近 0 越可复现；这是 MLPerf「5 次内差异 ≤5%」那条的自然对应量。
    public let repeatabilityCov: Double

    /// 顺序效应：样本序号与 TTFT 的相关系数。
    /// 显著为正说明「跑越久越慢」（热累积 / SSD 降速），此时前后段不可直接比。
    /// nil = 样本太少算不出。
    public let driftCorrelation: Double?

    public let thermalStatesSeen: [String]
    public let batteryDrainPercent: Double
    public let cachePolicy: String
}

// MARK: - 结果

public struct BenchmarkRunResult: Codable, Identifiable {

    public struct Meta: Codable {
        public let uuid: String
        public let startDatetime: String
        public let endDatetime: String
    }

    public struct Config: Codable {
        public let caseCount: Int
        public let repetitions: Int
        /// 是否跑了短预热（「你好」10 token，不计入统计）
        public let warmupEnabled: Bool
        /// 轮间冷却秒数
        public let cooldownSec: Double
        /// case 顺序策略说明
        public let orderPolicy: String
        public let decodeTokenLimit: Int
        public let prewarmAfterImage: Bool
        public let unloadMmproj: Bool
        public let datasetSource: String
        /// 实际生效的采样温度。**必须记录**：0 才是可复现的
        public let temperature: Float
        public let cachePolicy: String
        /// 执行模式。我们只有单流串行一种（引擎是单状态机，并发会读到错乱的 n_past）
        public let scenario: String
    }

    public let meta: Meta
    public let config: Config
    public let environment: BenchmarkEnvironment
    public let buildInfo: BenchmarkBuildInfo
    public let stats: BenchmarkStats

    public var id: String { meta.uuid }

    // MARK: - 构建

    public static func build(runId: String,
                             config: BenchmarkRunConfig,
                             samples: [BenchmarkSample],
                             temperature: Float,
                             measuredDurationSec: Double) -> BenchmarkRunResult {

        // 预热轮不进统计（但照样落盘，保留证据）
        let valid = samples.filter { $0.isValid && !$0.isWarmup }
        let warmupSamples = samples.filter { $0.isWarmup }

        let ttft = BenchmarkDescriptive(values: valid.map { $0.ttftEndToEndMs })
        let tpot = BenchmarkDescriptive(values: valid.compactMap { $0.tpotMs })
        let pRate = BenchmarkDescriptive(values: valid.compactMap { $0.prefillTokensPerSec })
        let dRate = BenchmarkDescriptive(values: valid.compactMap { $0.decodeTokensPerSec })

        func meanOf(_ f: (BenchmarkSample) -> Double) -> Double {
            guard !valid.isEmpty else { return 0 }
            return valid.map(f).reduce(0, +) / Double(valid.count)
        }
        let breakdown = BenchmarkBreakdown(
            imageEncodeMs: meanOf { $0.imageEncodeMs },
            prewarmMs: meanOf { $0.prewarmMs },
            prepMs: meanOf { $0.prepMs },
            prefillMs: meanOf { $0.prefillMs },
            decodeMs: meanOf { $0.decodeMs },
            wallMs: meanOf { $0.wallMs },
            unaccountedMs: meanOf { $0.unaccountedMs }
        )

        // prefill 的仿射特性：t = a + b·tokens
        let prefillFit: BenchmarkPrefillFit? = BenchmarkDescriptive.fit(
            xs: valid.map { Double($0.prefillTokens) },
            ys: valid.map { $0.prefillMs }
        ).map {
            BenchmarkPrefillFit(fixedMs: $0.intercept,
                                msPerToken: $0.slope,
                                marginalTokensPerSec: $0.slope > 0 ? 1000.0 / $0.slope : 0,
                                rSquared: $0.rSquared,
                                n: $0.n)
        }

        // 逐 case
        let keys = Set(valid.map { $0.caseKey }).sorted()
        let perCase: [BenchmarkCaseSummary] = keys.map { k in
            let group = valid.filter { $0.caseKey == k }
            let t = group.map { $0.ttftEndToEndMs }
            let p = group.compactMap { $0.tpotMs }
            return BenchmarkCaseSummary(
                caseKey: k,
                n: group.count,
                meanTTFTMs: t.isEmpty ? 0 : t.reduce(0, +) / Double(t.count),
                medianTTFTMs: BenchmarkDescriptive(values: t).median,
                meanTPOTMs: p.isEmpty ? 0 : p.reduce(0, +) / Double(p.count),
                meanPrefillTokens: group.map { Double($0.prefillTokens) }.reduce(0, +) / Double(group.count),
                meanImageTokens: group.map { Double($0.imageTokens) }.reduce(0, +) / Double(group.count),
                promptUTF8Length: group.first?.promptUTF8Length ?? 0
            )
        }

        // 可复现性：每个 case 跨轮次的 CoV，取中位数
        let perCaseCovs: [Double] = keys.compactMap { k in
            let group = valid.filter { $0.caseKey == k }
            guard group.count > 1 else { return nil }
            return BenchmarkDescriptive(values: group.map { $0.ttftEndToEndMs }).cov
        }
        let repeatabilityCov = perCaseCovs.isEmpty ? 0
            : BenchmarkDescriptive(values: perCaseCovs).median

        // 顺序效应：样本序号 vs TTFT 的相关系数
        let order = valid.enumerated().map { Double($0.offset) }
        let drift = BenchmarkDescriptive.pearson(order, valid.map { $0.ttftEndToEndMs })

        let drains = valid.compactMap { s -> Double? in
            guard s.batteryBefore >= 0, s.batteryAfter >= 0 else { return nil }
            return Double(s.batteryBefore - s.batteryAfter) * 100.0
        }

        let stats = BenchmarkStats(
            sampleCount: valid.count,
            requestedSampleCount: samples.count,
            warmupDiscarded: warmupSamples.count,
            measuredDurationSec: measuredDurationSec,
            ttft: ttft,
            tpot: tpot,
            prefillTokensPerSec: pRate,
            decodeTokensPerSec: dRate,
            prefillFit: prefillFit,
            decodeTokenLength: BenchmarkDescriptive(values: valid.map { Double($0.decodeTokens) }),
            breakdown: breakdown,
            perCase: perCase,
            repeatabilityCov: repeatabilityCov,
            driftCorrelation: drift,
            thermalStatesSeen: Array(Set(samples.map { $0.thermalAfter })).sorted(),
            batteryDrainPercent: drains.reduce(0, +),
            cachePolicy: Self.cachePolicyText
        )

        let cfg = Config(
            // 只数计入统计的 case。预热样本的 caseKey 是 -1，
            // 用 samples 全量去数会把它当成第 13 个 case（实际 12 个）。
            caseCount: Set(valid.map { $0.caseKey }).count,
            repetitions: config.repetitions,
            warmupEnabled: config.warmupEnabled,
            cooldownSec: config.cooldownSec,
            orderPolicy: Self.orderPolicyText,
            decodeTokenLimit: config.decodeTokenLimit,
            prewarmAfterImage: config.prewarmAfterImage,
            unloadMmproj: Self.mmprojUnloadEnabled,
            datasetSource: BenchmarkCaseStore.planDescription(),
            temperature: temperature,
            cachePolicy: Self.cachePolicyText,
            scenario: "SingleStream"
        )

        return BenchmarkRunResult(
            meta: Meta(uuid: runId,
                       startDatetime: samples.first?.startISO ?? "",
                       endDatetime: Self.nowISO()),
            config: cfg,
            environment: BenchmarkEnvironment.current(),
            buildInfo: BenchmarkBuildInfo.current(),
            stats: stats
        )
    }

    /// 缓存策略的固定声明文本。每个 case 前清 KV 是我们能给的隔离强度；
    /// 引擎内部的专家 slot 缓存无法按 case 清空（它只在进程存活期内有效），
    /// 这一点必须如实写出来，不能含糊。
    public static let cachePolicyText =
        "每个 case 前调用 clearKVCacheForNewTurn() 清空 KV；" +
        "输出长度受 decodeTokenLimit 约束：`-benchMaxTokens` 下它只是上限（撞 EOG 提前停），" +
        "`-benchTokens` 下是固定步数（忽略 EOG 强行补满，见 MTMDWrapper）；" +
        "引擎内 MoE 专家 slot 缓存按进程存活期存在，无法逐 case 清空，" +
        "因此 case 顺序会影响专家命中率 —— 已用轮次轮转对冲，见 orderPolicy。"

    /// 顺序与预热策略，写进结果里供复核。
    public static let orderPolicyText =
        "拉丁方轮转：第 r 轮把起始 case 后移 r 位，使每条 case 在各轮中占据不同位次，" +
        "避免固定顺序把「位次冷热」伪装成 case 间差异。" +
        "正式跑批前先跑一句「你好」10 token 作为短预热（落盘但不计入统计），" +
        "目的是把专家页与 GPU 频率走热，而不是丢弃一整轮有效数据。"

    /// 图像回合后是否卸载 mmproj（视觉塔）。
    ///
    /// 未设 `MB_MOE_UNLOAD_MMPROJ` 时桥接层默认开启（`MBMtmd.mm:1049`）。
    /// 实测 prep_ms 只有 35~372 ms —— mmproj 是 mmap 的，重载只是重新映射，
    /// 页面仍在页缓存里，**不是**显著的 I/O 开销。
    private static var mmprojUnloadEnabled: Bool {
        guard let v = ProcessInfo.processInfo.environment["MB_MOE_UNLOAD_MMPROJ"] else {
            return true
        }
        return !(v.isEmpty || v == "0")
    }

    private static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

// MARK: - 落盘

public enum BenchmarkResultStore {

    /// 结果根目录：<Documents>/benchmark_results/
    public static func rootURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return docs.appendingPathComponent("benchmark_results", isDirectory: true)
    }

    public static func resultFileURL(_ runId: String) -> URL {
        rootURL().appendingPathComponent("run_\(runId).json")
    }

    public static func telemetryFileURL(_ runId: String) -> URL {
        rootURL().appendingPathComponent("telemetry_\(runId).jsonl")
    }

    /// 落盘：一份汇总 JSON + 一份逐条明细 jsonl。
    /// 明细必须单独留 —— 统计口径可以事后换，但原始明细丢了就补不回来。
    public static func save(result: BenchmarkRunResult, samples: [BenchmarkSample]) throws {
        let dir = rootURL()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(result)
        try data.write(to: resultFileURL(result.meta.uuid))

        var lines: [String] = []
        let lineEnc = JSONEncoder()
        lineEnc.outputFormatting = [.sortedKeys]
        for s in samples {
            let d = try lineEnc.encode(s)
            if let str = String(data: d, encoding: .utf8) { lines.append(str) }
        }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: telemetryFileURL(result.meta.uuid),
                   atomically: true,
                   encoding: .utf8)
    }

    public static func listResults() -> [URL] {
        let dir = rootURL()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix("run_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
