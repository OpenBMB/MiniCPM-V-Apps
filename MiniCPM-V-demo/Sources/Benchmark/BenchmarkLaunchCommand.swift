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
//        com.tianchi.minicpmvdemo-test -bench -benchReps 2 -benchTokens 25
//
//  参数：
//    -bench                 触发无人值守跑批（必需）
//    -benchReps N           重复轮数，默认 1
//    -benchTokens N         固定输出 token 数，默认 25
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
                           warmupEnabled: (value("-benchWarmup").flatMap(Int.init) ?? 1) != 0,
                           cooldownSec: value("-benchCooldown").flatMap(Double.init) ?? 0,
                           caseIds: nil,
                           stayAlive: args.contains("-benchStay"))

        if let raw = value("-benchCases") {
            let ids = raw.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            opts.caseIds = ids.isEmpty ? nil : ids
        }

        // 下限保护：0 轮什么都不跑，静默返回空结果比直接报错更难查
        opts.repetitions = max(1, opts.repetitions)
        opts.decodeTokenLimit = max(1, opts.decodeTokenLimit)


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
        setvbuf(stdout, nil, _IONBF, 0)

        log("[BENCH] start reps=\(opts.repetitions) warmup=\(opts.warmupEnabled) "
            + "cooldown=\(opts.cooldownSec)s tokens=\(opts.decodeTokenLimit) "
            + "cases=\(opts.caseIds.map { $0.map(String.init).joined(separator: ",") } ?? "all") "
            + "stay=\(opts.stayAlive)")
        log("[BENCH] temperature=\(BenchmarkRunner.effectiveTemperature(example: example))")

        Task { @MainActor in
            do {
                var cases = try BenchmarkCaseStore.load()
                if let ids = opts.caseIds {
                    cases = cases.filter { ids.contains($0.key) }
                }
                guard !cases.isEmpty else {
                    log("[BENCH] error: 过滤后没有可用 case")
                    if !opts.stayAlive { exit(2) }
                    return
                }
                log("[BENCH] cases=\(cases.count) source=\(BenchmarkCaseStore.currentSource().rawValue)")

                let runner = BenchmarkRunner()
                await runner.run(cases: cases,
                                 config: BenchmarkRunConfig(repetitions: opts.repetitions,
                                                            decodeTokenLimit: opts.decodeTokenLimit,
                                                            warmupEnabled: opts.warmupEnabled,
                                                            cooldownSec: opts.cooldownSec),
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
                log("[BENCH] summary \(BenchmarkReport.oneLine(result))")
                log("[BENCH] json=\(BenchmarkResultStore.resultFileURL(result.meta.uuid).path)")
                log("[BENCH] jsonl=\(BenchmarkResultStore.telemetryFileURL(result.meta.uuid).path)")

                log("[BENCH] done")
                if !opts.stayAlive { exit(0) }
                log("[BENCH] stay alive：可在界面上查看结果或手动复跑")
            } catch {
                log("[BENCH] error: \(error.localizedDescription)")
                if !opts.stayAlive { exit(2) }
            }
        }
        return true
    }

    private static func log(_ s: String) {
        print(s)
        fflush(stdout)
    }
}
