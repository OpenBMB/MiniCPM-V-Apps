//
//  BenchmarkCase.swift
//  MiniCPM-V-demo
//
//  批量基准测试的数据集：一条 case = 一张图 + 一句文本。
//
//  文件格式是 **jsonl**（一行一条），字段命名沿用 MLPerf Mobile 的
//  `llm/dataset/ifeval_33.jsonl`：`key` 做主键、`image` / `text` 是我们的多模态扩展。
//
//  数据集按 **track** 组织（一次只跑一条 track），存在两处：
//  - bundle 内置：`Resources/Benchmark/<track>/`，随 App 一起分发；
//  - 设备侧：`Documents/benchmark/<track>/`，**App 启动时自动从 bundle 铺好**，
//    之后可直接改（换图/改提示词），不用重编译。
//
//  现有 track：`mmmu_qa_100`（100 条，图 + 文单选）、`mlperf_llm`（133 条，纯文本）。
//  用 `-benchDataset <track>` 选择，默认 `mmmu_qa_100`。
//

import Foundation

/// 一条测试 case。
public struct BenchmarkCase: Codable, Identifiable, Equatable {

    /// 主键，对应 MLPerf 数据集里的 `key`。
    public let key: Int

    /// 图片文件名，相对 `BenchmarkCaseStore.rootURL`；纯文本 case 可为 nil。
    public let image: String?

    /// 提问文本。
    ///
    /// 批量测试要求**每条 case 的输出长度可比**，所以文本必须固定长度
    /// （沿用桌面侧「各自恰好 2 token」的口径）；文本长度不同会让
    /// prefill 的 token 数不同，进而让 TTFT 混进无关变量。
    public let text: String

    public var id: Int { key }

    public init(key: Int, image: String?, text: String) {
        self.key = key
        self.image = image
        self.text = text
    }
}

/// 数据集来自哪里。写进报告，因为「用的是哪份数据集」直接决定数字能不能对比。
public enum BenchmarkCaseSource: String {
    /// App 内置（bundle）。跨设备一致，是基准口径。
    case builtin
    /// 用户放进 Documents 的自定义数据集。
    case documents
}

/// 数据集的读写。
///
/// 解析顺序：**Documents 优先，回退 bundle**。
/// - bundle 里那份随 App 分发（见 `Resources/Benchmark/<track>/`），
///   打进包里是为了保证跨设备、跨会话的数据集完全一致 —— 靠手工往每台设备拷
///   文件保证不了这一点，拷漏一张图跑出来的数就不可比。
/// - Documents 里放了则以它为准，用于换数据集或临时替换某几张图。
public enum BenchmarkCaseStore {

    /// 内置有哪些 track（顺序即 UI 里的展示顺序）。
    public static let bundledTracks = ["mmmu_qa_100", "mlperf_llm"]

    /// 默认 track。
    public static let defaultTrack = "mmmu_qa_100"

    /// 多选时存哪个 key（UI 里勾选的 track 列表）。
    public static let tracksDefaultsKey = "bench_dataset_tracks"

    /// 每条 track 要跑多少条（0 = 不跑）的持久化 key。
    public static let planDefaultsKey = "bench_dataset_plan"

    /// 运行时覆盖（UI 上拖滑条时写入）。优先级最高，
    /// 否则界面上改了数量、却因为启动参数还在而跑回原来那条，很难查。
    public static var overridePlan: [String: Int]?

    /// 某条 track 的条数缓存（UI 每次拖滑条都要读，避免反复解析 jsonl）。
    private static var totalCache: [String: Int] = [:]

    /// 某条 track 一共有多少条 case。
    public static func trackTotal(_ track: String) -> Int {
        if let c = totalCache[track] { return c }
        let n = ((try? casesURL(track: track)).flatMap { try? decode(contentsOf: $0).count }) ?? 0
        totalCache[track] = n
        return n
    }

    private static func clamp(_ plan: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in plan where bundledTracks.contains(k) {
            out[k] = max(0, min(v, trackTotal(k)))
        }
        return out
    }

    /// 本次要跑的「每条 track 跑多少条」。0 表示不跑。
    ///
    /// 优先级：`overridePlan`（UI）→ `-benchDataset a,b`（各跑满）→ UserDefaults → 默认（默认 track 跑满）。
    public static func selectedPlan() -> [String: Int] {
        if let over = overridePlan, over.values.contains(where: { $0 > 0 }) {
            return clamp(over)
        }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-benchDataset"), i + 1 < args.count {
            let list = args[i + 1].split(separator: ",").map(String.init)
                .filter { bundledTracks.contains($0) }
            if !list.isEmpty {
                return Dictionary(uniqueKeysWithValues: list.map { ($0, trackTotal($0)) })
            }
        }
        if let saved = UserDefaults.standard.dictionary(forKey: planDefaultsKey) as? [String: Int] {
            let c = clamp(saved)
            if c.values.contains(where: { $0 > 0 }) { return c }
        }
        return [defaultTrack: trackTotal(defaultTrack)]
    }

    /// 写入滑条选择。
    public static func setPlan(_ plan: [String: Int]) {
        let c = clamp(plan)
        overridePlan = c
        UserDefaults.standard.set(c, forKey: planDefaultsKey)
    }

    /// 有勾选（数量 > 0）的 track，按内置顺序。
    public static func selectedTracks() -> [String] {
        let plan = selectedPlan()
        let picked = bundledTracks.filter { (plan[$0] ?? 0) > 0 }
        return picked.isEmpty ? [defaultTrack] : picked
    }



    /// 写进结果元数据的「数据集来源 + 各 track 实际条数」，例如
    /// `documents · mmmu_qa_100=100,mlperf_llm=0` —— 事后能还原跑的是哪一档数据。
    public static func planDescription() -> String {
        let plan = selectedPlan()
        let parts = bundledTracks.map { "\($0)=\(plan[$0] ?? 0)" }.joined(separator: ",")
        return "\(currentSource().rawValue) · \(parts)"
    }

    /// 当前生效的 track。
    ///
    /// 优先级：`overrideTrack`（UI）→ `-benchDataset <track>` → UserDefaults → 默认。
    /// 传入的 track 不在内置列表里时回退到默认，避免打错一个字就找不到数据集。
    public static func activeTrack() -> String { selectedTracks().first ?? defaultTrack }

    /// 设备侧数据集目录：<Documents>/benchmark/<track>/
    ///
    /// 一条 track 一个目录（`cases.jsonl` 与图片必须**同级扁平存放**，见数据集的 README）。
    public static func rootURL(track: String? = nil) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return docs.appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent(track ?? activeTrack(), isDirectory: true)
    }

    /// bundle 里某条 track 的目录：<Bundle>/Benchmark/<track>/
    public static func bundledTrackURL(_ track: String? = nil) -> URL? {
        guard let base = builtinURL() else { return nil }
        let url = base.appendingPathComponent(track ?? activeTrack(), isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func casesFileURL() -> URL {
        rootURL().appendingPathComponent("cases.jsonl")
    }

    /// bundle 里的内置数据集目录。
    public static func builtinURL() -> URL? {
        Bundle.main.url(forResource: "Benchmark", withExtension: nil)
    }

    /// 当前生效的数据集来源。
    public static func currentSource() -> BenchmarkCaseSource {
        FileManager.default.fileExists(atPath: casesFileURL().path) ? .documents : .builtin
    }

    /// 某条 case 的图片路径。
    ///
    /// 查找顺序：Documents/<track>/ → bundle/<track>/ →（兼容旧布局）Documents/benchmark/ → 原路径。
    public static func imageURL(_ name: String) -> URL {
        let fm = FileManager.default
        let custom = rootURL().appendingPathComponent(name)
        if fm.fileExists(atPath: custom.path) { return custom }

        // 多选时图片可能来自别的 track：按顺序把所有 track 都试一遍
        for t in selectedTracks() where t != activeTrack() {
            let d = rootURL(track: t).appendingPathComponent(name)
            if fm.fileExists(atPath: d.path) { return d }
        }
        for t in bundledTracks {
            if let b = bundledTrackURL(t)?.appendingPathComponent(name), fm.fileExists(atPath: b.path) {
                return b
            }
        }

        // 兼容：数据集直接平铺在 Documents/benchmark/ 下的旧布局
        let legacy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent(name)
        if fm.fileExists(atPath: legacy.path) { return legacy }

        return custom // 都不存在时返回原路径，让下游报出明确的错误
    }

    /// 读一条 track 的 cases.jsonl（设备侧优先，回退 bundle）。
    private static func casesURL(track: String) throws -> URL {
        let fm = FileManager.default
        let docs = rootURL(track: track).appendingPathComponent("cases.jsonl")
        if fm.fileExists(atPath: docs.path) { return docs }
        if let b = bundledTrackURL(track)?.appendingPathComponent("cases.jsonl"),
           fm.fileExists(atPath: b.path) {
            return b
        }
        // 兼容旧布局：Documents/benchmark/cases.jsonl（只有单条 track 时代）
        let legacy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent("cases.jsonl")
        if fm.fileExists(atPath: legacy.path) { return legacy }
        throw BenchmarkCaseError.notFound
    }

    /// 读多条 track 并拼接（顺序同 `tracks`）。
    public static func load(tracks: [String]) throws -> [BenchmarkCase] {
        var out: [BenchmarkCase] = []
        for t in tracks { out += try decode(contentsOf: try casesURL(track: t)) }
        return out
    }

    /// 按「每条 track 跑多少条」拼出本次要跑的 case 列表（各取前 N 条）。
    public static func load(plan: [String: Int]) throws -> [BenchmarkCase] {
        var out: [BenchmarkCase] = []
        for t in bundledTracks {
            let n = min(max(0, plan[t] ?? 0), trackTotal(t))
            guard n > 0 else { continue }
            out += Array(try decode(contentsOf: try casesURL(track: t)).prefix(n))
        }
        return out
    }

    /// 读当前选择。
    public static func load() throws -> [BenchmarkCase] {
        try load(plan: selectedPlan())
    }

    /// 单条 track 的读取（保留给旧调用点）。
    public static func loadSingleTrack() throws -> [BenchmarkCase] {
        let fm = FileManager.default
        let legacyDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent("cases.jsonl")
        let candidates = [casesFileURL(),
                          bundledTrackURL()?.appendingPathComponent("cases.jsonl"),
                          legacyDocs]
            .compactMap { $0 }
            .first { fm.fileExists(atPath: $0.path) }
        let url = candidates

        guard let target = url, FileManager.default.fileExists(atPath: target.path) else {
            throw BenchmarkCaseError.notFound
        }
        return try decode(contentsOf: target)
    }

    private static func decode(contentsOf url: URL) throws -> [BenchmarkCase] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var result: [BenchmarkCase] = []

        for (offset, line) in raw.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            do {
                result.append(try JSONDecoder().decode(BenchmarkCase.self, from: data))
            } catch {
                throw BenchmarkCaseError.badLine(file: url.lastPathComponent,
                                                 line: offset + 1,
                                                 detail: String(describing: error))
            }
        }
        return result
    }

    /// 写数据集（只写到 Documents）。
    public static func save(_ cases: [BenchmarkCase]) throws {
        try ensureRootExists()
        var lines: [String] = []
        for c in cases {
            let data = try JSONEncoder().encode(c)
            guard let s = String(data: data, encoding: .utf8) else { continue }
            lines.append(s)
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: casesFileURL(), atomically: true, encoding: .utf8)
    }

    public static func ensureRootExists() throws {
        let url = rootURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true)
        }
    }
}

public enum BenchmarkCaseError: LocalizedError {
    case notFound
    case badLine(file: String, line: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 cases.jsonl（内置数据集缺失，且 Documents/benchmark/ 下也没有）"
        case .badLine(let file, let line, let detail):
            return "\(file) 第 \(line) 行解析失败：\(detail)"
        }
    }
}
