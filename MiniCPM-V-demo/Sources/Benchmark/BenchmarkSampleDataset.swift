//
//  BenchmarkSampleDataset.swift
//  MiniCPM-V-demo
//
//  内置数据集的导出工具。
//
//  内置数据集（bundle 里的 Resources/Benchmark/）由
//  `scripts/build_benchmark_dataset.py` 从 `35BA3B_cases.md` 生成，
//  包含 12 条真实 case（图 + 提示词），图片**原样拷贝、不做任何缩放或重编码** ——
//  分辨率与文件大小本身就是影响 mmproj 切片与首帧耗时的变量，动了就与 App
//  手工测的行为不一致。
//
//  本文件只提供一件事：把内置数据集导出到 Documents，方便用户改提示词或换图。
//  不导出也能直接跑 —— BenchmarkCaseStore 会回退到 bundle 里那份。
//

import Foundation

public enum BenchmarkSampleDataset {

    /// 内置数据集的 case 条数（用于 UI 文案；实际以 cases.jsonl 为准）。
    public static let builtinCaseCount = 12

    /// 把内置数据集导出到 <Documents>/benchmark/，之后用户可在「文件」App 里改。
    ///
    /// - Returns: 导出的文件数。
    public static func exportBuiltinToDocuments() throws -> Int {
        guard let builtin = BenchmarkCaseStore.builtinURL() else {
            throw BenchmarkDatasetError.builtinMissing
        }

        try BenchmarkCaseStore.ensureRootExists()
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: builtin, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }

        var n = 0
        for src in items {
            let dst = BenchmarkCaseStore.rootURL().appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            n += 1
        }
        return n
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
