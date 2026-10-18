//
//  BenchmarkReport.swift
//  MiniCPM-V-demo
//
//  把 BenchmarkRunResult 渲染成给人看的文本报告。
//
//  抽成独立类型的原因：界面上看的那份和无人值守跑出来的那份**必须是同一份**。
//  如果各写一遍，迟早会出现「界面显示 A、导出文件是 B」这种口径分叉，
//  而基准数据的可信度全靠口径一致。
//

import Foundation

public enum BenchmarkReport {

    private static func f(_ v: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v)
    }

    /// 一个指标的一整套统计量。
    ///
    /// 顺序按「读报告的人最需要什么」排：先给均值与它的不确定度，
    /// 再给稳健估计（中位数）与离散度，最后给分布两端与离群情况。
    private static func block(_ title: String, _ d: BenchmarkDescriptive, _ unit: String) -> String {
        var s = "  \(title)  (n=\(d.n))\n"
        if d.ci95Available {
            s += "    mean   \(f(d.mean)) \(unit)   95%CI [\(f(d.ci95Low)), \(f(d.ci95High))]  ±\(f(d.relativeCiHalfWidth * 100))%\n"
        } else {
            s += "    mean   \(f(d.mean)) \(unit)   95%CI 不可估计（n<2，不要拿它下结论）\n"
        }
        s += "    median \(f(d.median)) \(unit)   sd \(f(d.stddev))   CoV \(f(d.cov, 3))\n"
        s += "    min \(f(d.min)) · p25 \(f(d.p25)) · p75 \(f(d.p75)) · p90 \(f(d.p90)) · p95 \(f(d.p95)) · max \(f(d.max))\n"
        if d.outlierCount > 0 {
            s += "    离群 \(d.outlierCount) 个（修正 z>3.5）；剔除后 mean \(f(d.meanExcludingOutliers)) · CoV \(f(d.covExcludingOutliers, 3))\n"
        } else {
            s += "    离群 0 个（修正 z>3.5）\n"
        }
        // 样本量是否够，用统计回答而不是用档位规定回答
        if d.n >= 2, d.cov > 0 {
            let need = BenchmarkDescriptive.samplesNeeded(cov: d.cov, targetRelativeHalfWidth: 0.02)
            if d.relativeCiHalfWidth > 0.02 {
                s += "    精度不足：当前 ±\(f(d.relativeCiHalfWidth * 100))%，要压到 ±2% 约需 n≈\(need)（现 n=\(d.n)）\n"
            } else {
                s += "    精度：±\(f(d.relativeCiHalfWidth * 100))% 已达到 ±2% 目标\n"
            }
        }
        return s
    }

    /// 完整报告。
    public static func text(_ r: BenchmarkRunResult) -> String {
        let s = r.stats
        let c = r.config
        let e = r.environment
        let b = r.buildInfo

        var out = "run \(String(r.meta.uuid.prefix(8))) · \(c.scenario)\n"
        out += "计入统计 \(s.sampleCount) 条 / 共执行 \(s.requestedSampleCount) 条"
        out += "（丢弃预热 \(s.warmupDiscarded) 条）· 时长 \(f(s.measuredDurationSec)) s\n\n"

        // 主指标
        out += "【主指标】mean 为主（MLPerf 对 LLM 用 mean，非分位数）\n"
        out += block("TTFT（端到端：图编码+预热+prep+prefill）", s.ttft, "ms")
        out += block("TPOT（每输出 token）", s.tpot, "ms")
        out += block("prefill 速率", s.prefillTokensPerSec, "tok/s")
        out += block("decode 速率", s.decodeTokensPerSec, "tok/s")

        // 分项分解
        let bd = s.breakdown
        out += "\n【单条耗时分解】（各项均值，ms）\n"
        out += "    图编码 \(f(bd.imageEncodeMs)) · 预热 \(f(bd.prewarmMs)) · prep \(f(bd.prepMs))\n"
        out += "    prefill \(f(bd.prefillMs)) · decode \(f(bd.decodeMs))\n"
        out += "    wall \(f(bd.wallMs)) = 以上合计 \(f(bd.wallMs - bd.unaccountedMs)) + 未归项 \(f(bd.unaccountedMs))\n"
        out += "    （未归项 ≈ 10ms × 输出 token，是生成循环让出主线程的 sleep，不是计算开销）\n"

        // prefill 的仿射特性：比值指标在这里是错的
        if let fit = s.prefillFit {
            out += "\n【prefill 长度特性】t = \(f(fit.fixedMs)) ms + \(f(fit.msPerToken, 2)) ms/token"
            out += "   （R²=\(f(fit.rSquared, 3)), n=\(fit.n)）\n"
            out += "    固定开销 \(f(fit.fixedMs)) ms 与长度无关；边际吞吐 \(f(fit.marginalTokensPerSec, 0)) tok/s\n"
            out += "    ⚠️ 上面的「prefill 速率为一个比值」会被固定开销拖低：\n"
            out += "       短 prompt 显著偏低、长 prompt 才接近边际速率，两者不可直接比。\n"
        }

        // 输出长度：上限不等于定长
        let dl = s.decodeTokenLength
        out += "\n【输出长度】上限 \(c.decodeTokenLimit) token，实际 n=\(dl.n)  "
        out += "min \(Int(dl.min)) · median \(Int(dl.median)) · max \(Int(dl.max))\n"
        if dl.min < Double(c.decodeTokenLimit) {
            out += "    ⚠️ 有样本提前撞 EOG 停止（上限是**最大值不是定长**）。\n"
            out += "       TPOT / decode t/s 按 token 归一，仍可比；\n"
            out += "       但单条 wall 与能耗不可跨 case 比较，需按输出长度归一或另行固定长度。\n"
        }

        // 可复现性与顺序效应
        out += "\n【数据质量】\n"
        out += "    可复现性（同 case 轮间 CoV 中位数）\(f(s.repeatabilityCov, 3))\n"
        if let d = s.driftCorrelation {
            let warn = d > 0.5 ? " ⚠️ 明显正漂移，前后段不可直接比" : (d < -0.5 ? " ⚠️ 明显负漂移" : "")
            out += "    顺序效应（序号 vs TTFT 相关）\(f(d, 3))\(warn)\n"
        } else {
            out += "    顺序效应：样本不足，算不出\n"
        }
        out += "    热状态 \(s.thermalStatesSeen.joined(separator: ",")) · 电量消耗 \(f(s.batteryDrainPercent))%\n"

        // 逐 case
        out += "\n【逐 case】（TTFT ms / prefill tok / 图 tok）\n"
        for pc in s.perCase {
            out += "    #\(pc.caseKey)  n=\(pc.n)  mean \(f(pc.meanTTFTMs))  median \(f(pc.medianTTFTMs))" +
                   "  \(Int(pc.meanPrefillTokens))tok/\(Int(pc.meanImageTokens))img  prompt \(pc.promptUTF8Length)B\n"
        }

        // 配置与环境
        out += "\n【配置】\(c.caseCount) case × \(c.repetitions) 轮"
        out += c.warmupEnabled ? "（预热：「你好」\(BenchmarkRunConfig.warmupTokens) token，不计入）" : "（无预热）"
        out += "· 输出 \(c.decodeTokenLimit) token · 温度 \(c.temperature)"
        out += c.cooldownSec > 0 ? " · 轮间冷却 \(f(c.cooldownSec, 0))s\n" : "\n"
        out += "    预热 \(c.prewarmAfterImage) · mmproj 卸载 \(c.unloadMmproj) · 数据集 \(c.datasetSource)\n"
        out += "【顺序策略】\(c.orderPolicy)\n"
        out += "【环境】\(e.modelCode) · iOS \(e.osVersion) · RAM \(f(e.physicalMemoryGB)) GB · 低电量模式 \(e.lowPowerModeEnabled)\n"
        out += "【构建】v\(b.appVersion)(\(b.buildNumber)) · engine \(b.engineGitBranch)@\(b.engineGitCommit)" +
               " dirty=\(b.engineGitDirty.map(String.init) ?? "unknown")\n"
        out += "【缓存策略】\(s.cachePolicy)\n"

        return out
    }

    /// 单行摘要，便于脚本 grep。
    ///
    /// 无人值守跑批时每轮都打一行，一条命令就能看出趋势，不必等整批跑完再解析 JSON。
    public static func oneLine(_ r: BenchmarkRunResult) -> String {
        let s = r.stats
        return String(
            format: "samples=%d/%d ttft_mean=%.1fms ttft_ci=±%.1f%% tpot_mean=%.1fms "
                  + "prefill_tps=%.1f decode_tps=%.1f repeat_cov=%.3f",
            s.sampleCount, s.requestedSampleCount,
            s.ttft.mean, s.ttft.relativeCiHalfWidth * 100,
            s.tpot.mean,
            s.prefillTokensPerSec.mean, s.decodeTokensPerSec.mean,
            s.repeatabilityCov
        )
    }
}
