//
//  BenchmarkCase.swift
//  MiniCPM-V-demo
//
//  批量基准测试的数据集：一条 case = 一张图 + 一句文本。
//
//  文件格式是 **jsonl**（一行一条），字段命名沿用 MLPerf Mobile 的
//  `llm/dataset/ifeval_33.jsonl`：`key` 做主键、`image` / `text` 是我们的多模态扩展。
//
//  数据集放在 App 的 Documents/benchmark/ 下，通过「文件」App 或脚本可直接替换，
//  **换数据集不需要重编译 App** —— 这对批量测试是硬需求。
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
/// - bundle 里那份是从 `35BA3B_cases.md` 生成的 12 条内置数据集，
///   打进包里是为了保证跨设备、跨会话的数据集完全一致 —— 靠手工往每台设备拷
///   文件保证不了这一点，拷漏一张图跑出来的数就不可比。
/// - Documents 里放了则以它为准，用于换数据集或临时替换某几张图。
public enum BenchmarkCaseStore {

    /// 自定义数据集根目录：<Documents>/benchmark/
    public static func rootURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return docs.appendingPathComponent("benchmark", isDirectory: true)
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

    /// 某条 case 的图片路径：Documents 里有就用 Documents，否则用 bundle。
    public static func imageURL(_ name: String) -> URL {
        let custom = rootURL().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: custom.path) { return custom }
        if let builtin = builtinURL() {
            let b = builtin.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: b.path) { return b }
        }
        return custom // 都不存在时返回原路径，让下游报出明确的错误
    }

    /// 读数据集。
    public static func load() throws -> [BenchmarkCase] {
        let url = FileManager.default.fileExists(atPath: casesFileURL().path)
            ? casesFileURL()
            : builtinURL()?.appendingPathComponent("cases.jsonl")

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
