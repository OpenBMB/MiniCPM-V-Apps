//
//  BenchmarkEnvironment.swift
//  MiniCPM-V-demo
//
//  跑批结果里的「环境信息」与「构建信息」。
//
//  字段对齐 MLPerf Mobile `docs/result-spec.md` 的 `environment_info` 与 `build_info`
//  两段 —— 尤其是 `git_dirty_flag`：它要求结果里声明该二进制**是否含本地改动**。
//  这条很毒但很对，能防止「拿带实验改动的构建出的数字对外」。
//

import Foundation
import UIKit

// MARK: - 环境信息

public struct BenchmarkEnvironment: Codable {

    public let platform: String          // 固定 "ios"
    public let osVersion: String
    public let modelCode: String         // 例：iPhone14,5
    public let modelName: String         // 例：iPhone 13
    public let socName: String           // 尽力而为，取不到给 ""
    public let physicalMemoryGB: Double
    public let lowPowerModeEnabled: Bool

    public static func current() -> BenchmarkEnvironment {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return BenchmarkEnvironment(
            platform: "ios",
            osVersion: UIDevice.current.systemVersion,
            modelCode: Self.machineName(),
            modelName: UIDevice.current.model,
            socName: Self.socName(),
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// `hw.machine`，例 `iPhone14,5` / `iPad13,8`。
    private static func machineName() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// SoC 名。
    ///
    /// iOS **没有**公开 API 能读到 SoC 型号。曾经用 `hw.perflevel0.name` 兜底，
    /// 实测在 iPad 上返回的是 `"Performance"` —— 那是 Apple 给自家 CPU 核心起的
    /// 代号（Performance / Efficiency），不是 SoC 名，写进报告是噪声不是信息。
    /// 所以这里直接留空：**宁可空着也不要编一个像答案的错答案**。
    /// 需要 SoC 名时按 `modelCode`（如 iPad13,5）事后查表。
    private static func socName() -> String {
        return ""
    }
}

// MARK: - 构建信息

public struct BenchmarkBuildInfo: Codable {

    public let appVersion: String
    public let buildNumber: String
    /// 引擎分支与 commit。由构建脚本写入 Info.plist，取不到给空串。
    public let engineGitBranch: String
    public let engineGitCommit: String
    /// **是否含本地未提交改动**。取不到时给 nil 而不是 false —— 未知 ≠ 干净。
    public let engineGitDirty: Bool?

    public static func current() -> BenchmarkBuildInfo {
        let bundle = Bundle.main
        return BenchmarkBuildInfo(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            engineGitBranch: bundle.object(forInfoDictionaryKey: "EngineGitBranch") as? String ?? "",
            engineGitCommit: bundle.object(forInfoDictionaryKey: "EngineGitCommit") as? String ?? "",
            engineGitDirty: bundle.object(forInfoDictionaryKey: "EngineGitDirty") as? Bool
        )
    }
}
