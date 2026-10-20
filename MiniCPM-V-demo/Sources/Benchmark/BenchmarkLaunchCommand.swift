//
//  BenchmarkLaunchCommand.swift
//  MiniCPM-V-demo
//
//  无人值守跑批入口：用**启动参数**配置并执行，不需要在界面上点任何东西。
//
//  用法（模型会在 App 启动时自动加载，加载完这里自动接管）：
//
//    xcrun devicectl device process launch \
//        --device <UDID> --console --terminate-existing \
//        <你的 Bundle ID> -- -bench -benchReps 2 -benchMaxTokens 512
//
//  注意 `--` 分隔符：其后的参数才会被交给 App。
//
//  参数：
//    -bench                 触发无人值守跑批（必需）
//    -benchReps N           重复轮数，默认 1
//    -benchMaxTokens N      输出 token **上限**（撞 EOG 提前停）
//    -benchTokens N         旧口径：固定步数、忽略 EOG（默认 25）
//    -benchCases 1,2,3      只跑这些 case（默认全部）
//    -benchStay             跑完不退出，留在界面上看结果 / 手动复跑
//
//  设计取舍：
//  - 沿用工程里已有的 `-moeBench` 那套约定（启动参数 + 无缓冲 stdout + 跑完 exit），
//    不另造一套机制。
//  - 报告文本与界面**共用** `BenchmarkReport`，不会出现两份口径。
//  - 默认跑完就 exit：无人值守场景下，进程不退会一直占着 12 GB 模型内存，
//    下一轮启动会被 jetsam 干掉。
//

import Foundation

public enum BenchmarkLaunchCommand {

    public struct Options {
        /// 重复轮数
        public var repetitions: Int
        /// 固定输出 token 数
        public var decodeTokenLimit: Int
        /// 是否跑短预热（「你好」10 token，不计入统计）
        public var warmupEnabled: Bool
        /// 轮间冷却秒数
        public var cooldownSec: Double
        /// 只跑指定 case；nil = 全部
        public var caseIds: [Int]?
        /// 跑完不退出
        public var stayAlive: Bool
        /// 静默基线测量时长（秒）。0 = 不做。见 `measureIdle(_:)`。
        public var idleSec: Double
        /// `decodeTokenLimit` 是否退化为上限（撞 EOG 提前停）。
        public var stopAtEOG: Bool
        /// 每条 case 前是否清 KV。false = 对齐日常对话路径（对话从来不清）。
        public var resetKVBeforeCase: Bool
    }

    /// 触发开关。带 `-bench` 即启用。
    public static let flag = "-bench"

    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    /// 解析启动参数。没带 `-bench` 返回 nil。
    public static func parse() -> Options? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(flag) else { return nil }

        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        var opts = Options(repetitions: value("-benchReps").flatMap(Int.init) ?? 1,
                           decodeTokenLimit: value("-benchTokens").flatMap(Int.init) ?? 25,
                           warmupEnabled: (value("-benchWarmup").flatMap(Int.init) ?? 0) != 0,
                           cooldownSec: value("-benchCooldown").flatMap(Double.init) ?? 0,
                           caseIds: nil,
                           stayAlive: args.contains("-benchStay"),
                           idleSec: value("-benchIdleSec").flatMap(Double.init) ?? 0,
                           stopAtEOG: false,
                           resetKVBeforeCase: !args.contains("-benchNoReset"))

        // `-benchMaxTokens N`：N 是**上限**，模型撞 EOG 可以提前停（推荐口径）。
        // `-benchTokens N`：历史行为，忽略 EOG 强行生成到 N 步（固定长度，不再推荐）。
        if let raw = value("-benchMaxTokens"), let n = Int(raw) {
            opts.decodeTokenLimit = n
            opts.stopAtEOG = true
        }

        if let raw = value("-benchCases") {
            let ids = raw.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            opts.caseIds = ids.isEmpty ? nil : ids
        }

        // 下限保护：0 轮什么都不跑，静默返回空结果比直接报错更难查
        opts.repetitions = max(1, opts.repetitions)

        // decodeTokenLimit 的语义见 MTMDWrapper：`> 0` 是固定步数（忽略 EOG），
        // `<= 0` 是**不做长度限制、撞 EOG 自然停**。
        //
        // 这里原来无条件 `max(1, …)`，把 0 / -1 全夹成 1 ——
        // 于是「自然停止」被静默变成「固定生成 1 个 token」，
        // 日志只显示「达到固定步数上限 1」，看起来像模型自己停了，极难定位。
        // 现在只在真正要固定步数时才做下限保护。
        if opts.decodeTokenLimit > 0 {
            opts.decodeTokenLimit = max(1, opts.decodeTokenLimit)
        }


        return opts
    }

    /// 在模型加载完成后调用。带了 `-bench` 就接管，跑完打印报告并退出。
    ///
    /// - Returns: 是否接管了（调用方据此决定后续是否还要做别的）
    @discardableResult
    @MainActor
    public static func runIfRequested(example: MTMDWrapperExample?) -> Bool {
        guard let opts = parse() else { return false }
        guard let example = example else {
            log("[BENCH] error: 模型未加载，无法跑批")
            if !opts.stayAlive { exit(2) }
            return true
        }

        // devicectl --console 下 stdout 是管道，默认块缓冲 4 KB；
        // 进程被超时杀掉时缓冲全丢，日志白打。改为无缓冲。
        //
        // 试过改成 64 KB 全缓冲（推理段每 5 秒要吐 ~67 KB，会超过 64 KB 管道缓冲），
        // 实测速度没有变化（17.50/17.68/17.76 vs 无缓冲的 17.33/17.29/17.61），
        // 所以管道不是「bench 比对话慢 10%」的原因，保持无缓冲（日志不丢）。
        // 阶段标记与汇总行仍走 NSLog（logMark），不受这里影响。
        setvbuf(stdout, nil, _IONBF, 0)

        logMark("[BENCH] start reps=\(opts.repetitions) warmup=\(opts.warmupEnabled) "
            + "cooldown=\(opts.cooldownSec)s tokens=\(opts.decodeTokenLimit) "
            + "cases=\(opts.caseIds.map { $0.map(String.init).joined(separator: ",") } ?? "all") "
            + "stay=\(opts.stayAlive)")
        log("[BENCH] temperature=\(BenchmarkRunner.effectiveTemperature(example: example))")

        // IOReport 能力探测：能不能拿到按域能耗（含 GPU）。
        // 失败不阻塞跑批，只留日志 —— 这正是我们要判断的事。
        // 注：全量通道普查版会在 CF 字典遍历处触发 SIGTRAP，已回退。
        // 现在只做一件事：问「Energy Model 组里到底有几个通道」—— 一个安全的最小检查。
        //   通道数 0  → iOS 不暴露该组，路断了
        //   通道数 >0 → 订阅仍失败 = 沙箱/entitlement 限制
        for line in BenchmarkIOReportProbe.debugLines(
            BenchmarkIOReportProbe.sample(seconds: 2.0), seconds: 2.0) {
            log(line)
        }

        Task { @MainActor in
            do {
                // 跑批前确保数据集已铺好（启动那次是后台异步的，可能还没跑完）
                let summary = (try? BenchmarkSampleDataset.installBundledDatasetsIfNeeded()) ?? "n/a"
                log("[BENCH] dataset=\(BenchmarkCaseStore.activeTrack()) install=\(summary)")

                var cases = try BenchmarkCaseStore.load()
                if let ids = opts.caseIds {
                    cases = cases.filter { ids.contains($0.key) }
                }
                guard !cases.isEmpty else {
                    log("[BENCH] error: 过滤后没有可用 case")
                    if !opts.stayAlive { exit(2) }
                    return
                }
                log("[BENCH] cases=\(cases.count) source=\(BenchmarkCaseStore.currentSource().rawValue)"
                    + " track=\(BenchmarkCaseStore.activeTrack())")

                // 静默基线：放在跑批**之前**测 —— 此时模型已加载但还没做过任何推理，
                // 量到的就是「屏幕 + DRAM 刷新 + 系统后台」的底噪。
                await measureIdle(seconds: opts.idleSec)

                let runner = BenchmarkRunner()
                await runner.run(cases: cases,
                                 config: BenchmarkRunConfig(repetitions: opts.repetitions,
                                                            decodeTokenLimit: opts.decodeTokenLimit,
                                                            warmupEnabled: opts.warmupEnabled,
                                                            cooldownSec: opts.cooldownSec,
                                                            resetKVBeforeCase: opts.resetKVBeforeCase,
                                                            stopAtEOG: opts.stopAtEOG),
                                 example: example)

                guard let result = runner.lastResult else {
                    log("[BENCH] error: \(runner.failureMessage ?? "未产生结果")")
                    if !opts.stayAlive { exit(2) }
                    return
                }

                // 报告与界面共用同一份渲染，避免口径分叉
                for line in BenchmarkReport.text(result).split(separator: "\n",
                                                               omittingEmptySubsequences: false) {
                    log("[BENCH] \(line)")
                }
                logMark("[BENCH] summary \(BenchmarkReport.oneLine(result))")
                log("[BENCH] json=\(BenchmarkResultStore.resultFileURL(result.meta.uuid).path)")
                log("[BENCH] jsonl=\(BenchmarkResultStore.telemetryFileURL(result.meta.uuid).path)")

                logMark("[BENCH] done")
                if !opts.stayAlive { exit(0) }
                logMark("[BENCH] stay alive：可在界面上查看结果或手动复跑")
            } catch {
                log("[BENCH] error: \(error.localizedDescription)")
                if !opts.stayAlive { exit(2) }
            }
        }
        return true
    }

    /// 静默基线：模型已加载、屏幕亮着、**不做任何推理**时的能量速率。
    ///
    /// 为什么需要它：
    /// - 推理期量到的能量里混着与模型无关的底噪（屏幕、DRAM 刷新、系统后台）。
    ///   A/B 做差时这块会被抵消，但要给任何绝对值就必须先量出来减掉。
    /// - 它同时是热基线：静默时若仍在升温，说明有别的东西在跑，推理数据就不可信。
    ///
    /// 注意用 `Task.sleep` 而不是 `Thread.sleep` —— 这里是 MainActor，
    /// 阻塞主线程会把 UI 卡死，长时间还可能被系统判成无响应。
    private static func measureIdle(seconds: Double) async {
        guard seconds > 0 else { return }

        let before  = BenchmarkEnergyProbe.take()
        let thermB  = ProcessInfo.processInfo.thermalState
        let t0      = Date()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let wallSec = Date().timeIntervalSince(t0)
        let after   = BenchmarkEnergyProbe.take()
        let thermA  = ProcessInfo.processInfo.thermalState

        let d = after.delta(since: before)
        let joules = Double(d["energyNJ"] ?? 0) / 1e9
        // ── 重要口径提醒 ──
        // `ri_energy_nj` 只覆盖 **CPU**（实测每 cycle 0.21~0.25 nJ，属小核 ARM 量级；
        // 且 GPU 满载 30 s 时它只有 2 J 量级，物理上不可能是整机功耗）。
        // 所以这里的「等效 W」**只是 CPU 侧的**，不含 GPU / 屏幕 / NAND，
        // 不能当成整机功耗对外发布。
        log(String(format: "[IDLE] 静默 %.1fs：cpuEnergy=%.4f J → CPU 等效 %.4f W | "
                         + "diskRead=%lld B gpuTime=%.2f ms instr=%lld | thermal=%@→%@",
                   wallSec, joules, joules / max(wallSec, 0.001),
                   d["diskioBytesRead"] ?? 0,
                   Double(d["gpuTimeNs"] ?? 0) / 1e6,
                   d["instructions"] ?? 0,
                   thermalName(thermB), thermalName(thermA)))
    }

    private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func log(_ s: String) {
        print(s)
        fflush(stdout)
    }

    /// 阶段标记 / 汇总行专用：走 NSLog，不经 stdout。
    ///
    /// stdout 现在是 64 KB 全缓冲（为了不堵 devicectl 的 console 管道），
    /// 而这些行是主机侧**实时**依赖的（切分推理段、取 decode_tps），
    /// 必须绕过缓冲立刻出去。NSLog 写的是 os_log，devicectl --console 能收到。
    private static func logMark(_ s: String) {
        NSLog("%@", s)
    }
}
