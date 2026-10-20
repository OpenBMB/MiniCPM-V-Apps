//
//  BenchmarkStatistics.swift
//  MiniCPM-V-demo
//
//  描述统计与不确定度计算。
//
//  这里只做一件事：**把一组数算成能对外的一组数**。不做档位、不做合格/不合格判定
//  （那属于某个具体基准的规则，不是统计本身）。
//
//  口径说明（都取自 MLPerf 的做法，但剥掉了它针对特定模型的规则）：
//
//  1. **中心趋势用 mean，但 median 一起报。**
//     MLPerf Mobile 的 Performance run 表里，8 个模型里只有 LLM 两项写的是
//     `mean`（其余是 90%-ile）—— `mobile_inference_rules.adoc:153-161`。
//     所以 mean 是主指标；median 作为稳健估计并列给出，两者差得多说明分布有偏。
//
//  2. **分位数只在聚合层给，不在单样本层给。**
//     n=5 时 p90 就是第二大值、p95 无意义。分位数是描述「跨样本分布」的。
//
//  3. **必须给不确定度。** 只报一个均值等于没报 —— 均值 ± 95% 置信区间。
//     小样本用 t 分布而不是 1.96，否则会把 CI 报窄、显得比实际更确定。
//
//  4. **离群点用修正 z 分数（Iglewicz–Hoaglin）**：0.6745·(x−median)/MAD > 3.5。
//     且**剔除前后都报**，不静默丢数据。
//

import Foundation

/// 一组观测值的完整描述统计。
public struct BenchmarkDescriptive: Codable {

    public let n: Int
    public let mean: Double
    public let median: Double
    public let stddev: Double
    /// 变异系数 sd/mean，无量纲，用于跨量级比较离散程度
    public let cov: Double
    public let min: Double
    public let max: Double
    public let p25: Double
    public let p75: Double
    public let p90: Double
    public let p95: Double
    public let iqr: Double
    /// 中位数绝对偏差，离群判定的分母
    public let mad: Double
    public let ci95Low: Double
    public let ci95High: Double
    /// n < 2 时无法估标准差，置信区间不可信 —— 置 false，报告里会写明「样本不足」。
    /// 否则 n=1 会算出 [mean, mean] 这种「零宽区间」，看起来极其精确，实际是假的。
    public let ci95Available: Bool
    /// 相对置信区间半宽 = 半宽 / mean，如 0.08 表示 ±8%。
    ///
    /// 这是「这个均值有多准」的直接度量，**比任何合格判定都有用**：
    /// 读者看到 ±8% 就知道该不该拿它去做结论，不需要谁来盖章。
    public let relativeCiHalfWidth: Double
    /// 修正 z 分数超过 3.5 的点数
    public let outlierCount: Int
    /// 剔除离群点后的均值（与 mean 并列，不替换）
    public let meanExcludingOutliers: Double
    /// 剔除离群点后的变异系数
    public let covExcludingOutliers: Double

    /// 从原始观测值算出全部统计量。
    public init(values raw: [Double]) {
        let xs = raw.filter { $0.isFinite }
        let n = xs.count
        self.n = n

        guard n > 0 else {
            self.mean = 0; self.median = 0; self.stddev = 0; self.cov = 0
            self.min = 0; self.max = 0; self.p25 = 0; self.p75 = 0
            self.p90 = 0; self.p95 = 0; self.iqr = 0; self.mad = 0
            self.ci95Low = 0; self.ci95High = 0
            self.ci95Available = false; self.relativeCiHalfWidth = 0
            self.outlierCount = 0
            self.meanExcludingOutliers = 0; self.covExcludingOutliers = 0
            return
        }

        let s = xs.sorted()
        let mean = xs.reduce(0, +) / Double(n)
        let median = Self.percentile(sorted: s, 50)

        // 样本标准差（n-1）
        let sd: Double = {
            guard n > 1 else { return 0 }
            let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
            // 注意：本结构体有名为 min/max 的存储属性，会遮蔽全局函数，必须写 Swift.max
            return sqrt(Swift.max(0, v))
        }()

        let mad = Self.mad(sorted: s)
        let p25 = Self.percentile(sorted: s, 25)
        let p75 = Self.percentile(sorted: s, 75)

        self.mean = mean
        self.median = median
        self.stddev = sd
        self.cov = mean != 0 ? sd / abs(mean) : 0
        self.min = s.first ?? 0
        self.max = s.last ?? 0
        self.p25 = p25
        self.p75 = p75
        self.p90 = Self.percentile(sorted: s, 90)
        self.p95 = Self.percentile(sorted: s, 95)
        self.iqr = p75 - p25
        self.mad = mad

        // 均值的 95% 置信区间：小样本用 t 分布
        let se = n > 1 ? sd / sqrt(Double(n)) : 0
        let t = Self.tCritical95(df: n - 1)
        self.ci95Low = mean - t * se
        self.ci95High = mean + t * se
        self.ci95Available = n > 1
        self.relativeCiHalfWidth = (n > 1 && mean != 0) ? (t * se) / abs(mean) : 0

        // 离群点：修正 z 分数
        let kept: [Double]
        if mad > 0 {
            kept = xs.filter { abs(0.6745 * ($0 - median) / mad) <= 3.5 }
        } else {
            kept = xs   // MAD=0（超过半数取值相同）时不做剔除，否则会把正常点全杀掉
        }
        self.outlierCount = n - kept.count

        let kMean = kept.isEmpty ? mean : kept.reduce(0, +) / Double(kept.count)
        self.meanExcludingOutliers = kMean
        if kept.count > 1 {
            let kv = kept.reduce(0) { $0 + ($1 - kMean) * ($1 - kMean) } / Double(kept.count - 1)
            let ksd = sqrt(Swift.max(0, kv))
            self.covExcludingOutliers = kMean != 0 ? ksd / abs(kMean) : 0
        } else {
            self.covExcludingOutliers = 0
        }
    }

    // MARK: - 基础统计函数

    /// 最近秩次法（nearest-rank）分位数。
    ///
    /// 不插值：小样本下插值出来的分位数没有实际观测支撑，
    /// 最近秩次法给出的永远是真实出现过的取值。
    public static func percentile(sorted s: [Double], _ p: Double) -> Double {
        guard !s.isEmpty else { return 0 }
        let idx = Int(ceil(p / 100.0 * Double(s.count))) - 1
        return s[Swift.max(0, Swift.min(idx, s.count - 1))]
    }

    /// 中位数绝对偏差。
    public static func mad(sorted s: [Double]) -> Double {
        guard !s.isEmpty else { return 0 }
        let m = percentile(sorted: s, 50)
        let devs = s.map { abs($0 - m) }.sorted()
        return percentile(sorted: devs, 50)
    }

    /// 双尾 95% 的 t 临界值。df ≥ 31 取 1.96（正态近似）。
    ///
    /// 为什么不用固定 1.96：n=6 时 df=5，真值是 2.571 —— 用 1.96 会把置信区间
    /// 报窄 24%，看起来比实际更确定，这正是"不严谨"最常见的来源。
    public static func tCritical95(df: Int) -> Double {
        let table: [Double] = [
            12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
            2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
            2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
        ]
        guard df >= 1 else { return 12.706 }          // df=0 没法估，给最保守的
        if df <= table.count { return table[df - 1] }
        return 1.960
    }

    /// 要把均值估计到 ±`targetRelativeHalfWidth`（如 0.02 表示 ±2%），
    /// 在给定变异系数下需要多少样本。
    ///
    /// 由标准误定义反解：半宽 ≈ t·sd/√n = t·CoV·mean/√n ⇒ n = (t·CoV/半宽)²
    /// 这是「该跑多少条」的**统计答案**，替代「档位规定要跑几条」那种拍脑袋的做法：
    /// 离散度大的指标自然要求更多样本，而不是所有指标一个数。
    public static func samplesNeeded(cov: Double, targetRelativeHalfWidth: Double) -> Int {
        guard cov > 0, targetRelativeHalfWidth > 0 else { return 0 }
        let n = pow(1.96 * cov / targetRelativeHalfWidth, 2)
        return Swift.max(1, Int(ceil(n)))
    }

    /// 最小二乘直线拟合的系数。
    public struct LinearFit {
        /// 截距：x=0 时的 y，即「与规模无关的固定开销」
        public let intercept: Double
        /// 斜率：每增加 1 个 x 带来的 y 增量
        public let slope: Double
        /// 拟合优度，接近 1 说明确实是一条直线
        public let rSquared: Double
        public let n: Int
    }

    /// 对一组 (x, y) 做最小二乘直线拟合 `y = intercept + slope·x`。
    ///
    /// 用途：prefill 耗时对 token 数**不是过原点的正比关系**，而是一条有截距的直线
    /// （固定开销 + 每 token 线性）。所以「prefill tok/s」这个比值指标在不同 prompt
    /// 长度之间根本没有可比性 —— 短 prompt 被固定开销拖低，长 prompt 才接近边际速率。
    /// 必须用截距+斜率两个数来描述，比值只是两者混在一起后的产物。
    public static func fit(xs: [Double], ys: [Double]) -> LinearFit? {
        let n = Swift.min(xs.count, ys.count)
        guard n >= 3 else { return nil }
        let mx = xs.prefix(n).reduce(0, +) / Double(n)
        let my = ys.prefix(n).reduce(0, +) / Double(n)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in 0..<n {
            let dx = xs[i] - mx
            let dy = ys[i] - my
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else { return nil }
        let b = sxy / sxx
        let a = my - b * mx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1.0
        return LinearFit(intercept: a, slope: b, rSquared: r2, n: n)
    }

    /// 皮尔逊相关系数，用于检测顺序效应（跑得越久越慢的漂移）。
    public static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        let n = Swift.min(xs.count, ys.count)
        guard n >= 3 else { return nil }
        let mx = xs.prefix(n).reduce(0, +) / Double(n)
        let my = ys.prefix(n).reduce(0, +) / Double(n)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<n {
            let dx = xs[i] - mx
            let dy = ys[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / sqrt(sxx * syy)
    }
}
