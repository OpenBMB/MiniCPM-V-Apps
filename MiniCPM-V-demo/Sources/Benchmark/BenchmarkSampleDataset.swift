//
//  BenchmarkSampleDataset.swift
//  MiniCPM-V-demo
//
//  内置数据集（bundle 里的 `Resources/Benchmark/<track>/`）的安装与导出工具。
//
//  数据集本身在 `datasets/benchmark_v2/` 里生成（见该目录的 README）：
//  - `vision_mix_50`：50 条，25 条已审核真实 case + 25 条识图/描述/短答图文（**默认 track**）
//  - `mlperf_llm`：133 条，MLPerf Mobile v6.0 Tiny-MMLU + Tiny-IFEval-33，纯文本
//
//  为什么要在启动时"铺"到 Documents：
//  1. 批量测试要能**换图/改提示词而不重编译**，所以运行时读的是 Documents；
//  2. 但"靠人工往每台设备拷文件"保证不了跨设备一致（漏一张图数据就不可比），
//     所以 bundle 里存一份，启动时自动铺到 `Documents/benchmark/<track>/`。
//
//  铺的动作是幂等的：用 `.installed` 戳记（内容 = 版本 + 源文件数）判断是否需要重铺。
//

import Foundation

public enum BenchmarkSampleDataset {

    /// 安装戳记的版本号。**改数据集内容时把它 +1**，已装过的设备才会重铺。
    // 只改 cases.jsonl 的内容（增删 case、改写 prompt）时文件数不变，只能靠版本号触发重铺。
    public static let installVersion = "v6"

    /// 默认 track 的 case 条数（UI 文案用；实际以 cases.jsonl 为准）。
    public static let builtinCaseCount = 50

    /// 把 bundle 里的每条 track 铺到 `Documents/benchmark/<track>/`。
    ///
    /// - Parameter force: true 时无视戳记强制重铺。
    /// - Returns: 人类可读的摘要，形如 `vision_mix_50=installed(34), mlperf_llm=cached(6)`。
    @discardableResult
    public static func installBundledDatasetsIfNeeded(force: Bool = false) throws -> String {
        guard let base = BenchmarkCaseStore.builtinURL() else {
            throw BenchmarkDatasetError.builtinMissing
        }
        let fm = FileManager.default
        var parts: [String] = []

        for track in BenchmarkCaseStore.bundledTracks {
            let src = base.appendingPathComponent(track, isDirectory: true)
            guard fm.fileExists(atPath: src.appendingPathComponent("cases.jsonl").path) else {
                parts.append("\(track)=missing")
                continue
            }

            let dst = BenchmarkCaseStore.rootURL(track: track)
            let stamp = dst.appendingPathComponent(".installed")
            let srcItems = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }
            let want = "\(installVersion):\(srcItems.count)"

            if !force,
               let have = try? String(contentsOf: stamp, encoding: .utf8),
               have.trimmingCharacters(in: .whitespacesAndNewlines) == want {
                parts.append("\(track)=cached(\(srcItems.count))")
                continue
            }

            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)

            var n = 0
            for item in srcItems {
                try fm.copyItem(at: item, to: dst.appendingPathComponent(item.lastPathComponent))
                n += 1
            }
            try want.write(to: stamp, atomically: true, encoding: .utf8)
            parts.append("\(track)=installed(\(n))")
        }

        return parts.joined(separator: ", ")
    }

    /// 把**当前 track** 重新铺一遍（UI 上的「重置数据集」用）。
    @discardableResult
    public static func reinstallActiveTrack() throws -> String {
        try installBundledDatasetsIfNeeded(force: true)
    }

    /// 删掉设备侧某条 track 的副本（→ 下次启动会重新铺）。
    public static func removeInstalled(track: String? = nil) throws {
        let root = BenchmarkCaseStore.rootURL(track: track)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// 兼容旧接口：等价于「强制重铺当前 track」。
    @discardableResult
    public static func exportBuiltinToDocuments() throws -> Int {
        let summary = try reinstallActiveTrack()
        // 旧接口返回文件数；这里从摘要里解析不出来就退化为 0，只用于 UI 提示语。
        print("[DATASET] export -> \(summary)")
        return BenchmarkCaseStore.bundledTracks.count
    }

    /// 删掉 Documents 下那份自定义数据集，恢复用内置数据集。
    public static func removeCustomDataset() throws {
        let root = BenchmarkCaseStore.rootURL()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}

public enum BenchmarkDatasetError: LocalizedError {
    case builtinMissing

    public var errorDescription: String? {
        switch self {
        case .builtinMissing:
            return "App 包内缺少内置数据集（Resources/Benchmark）"
        }
    }
}
