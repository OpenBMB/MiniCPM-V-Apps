//
//  BenchmarkIOReportProbe.swift
//  MiniCPM-V-demo
//
//  任务 2：用私有 IOReport 框架读**按域能耗**（CPU / GPU / ANE / DRAM）。
//
//  为什么需要它：
//  `proc_pid_rusage` 的 `ri_energy_nj` 只覆盖 CPU（实测每 cycle 0.21~0.25 nJ，
//  且 GPU 满载 30 s 时它只有 2 J 量级）—— 拿它回答「GPU 还是 SSD 谁是大头」
//  是不成立的。IOReport 的 "Energy Model" 组直接给**各子系统能量**，
//  和 `powermetrics` 同源，而且是用户态 API，不需要 root。
//
//  ⚠️ 这是**私有 API**：仅用于内部测量构建，不进 App Store。
//  用 `dlopen` + `dlsym` 而不是链接，这样：
//    1) 编译期不依赖私有符号，不会因为符号不存在而链接失败；
//    2) 运行时缺库/缺函数能优雅降级成一条日志，而不是崩。
//
//  V1 目的：确认 iOS 17.7 上到底有没有这个组、有没有 GPU 通道、单位是什么。
//

import Foundation

// MARK: - 采样结果

public struct IOReportDomainSample {
    public let channelName: String
    public let subgroup: String
    /// 该通道在两次采样之间的增量（原始计数单位，未换算）。
    public let delta: Int64
}

public struct IOReportProbeResult {
    public let dlopenOK: Bool
    public let missingSymbols: [String]
    public let groupFound: Bool
    public let channels: [IOReportDomainSample]
    public let note: String
}

// MARK: - 探针

public enum BenchmarkIOReportProbe {

    /// "Energy Model" 是 powermetrics 用的组名；子组留空表示全部。
    private static let groupName = "Energy Model" as CFString

    public static func sample(seconds: Double = 2.0) -> IOReportProbeResult {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            let err = String(cString: dlerror() ?? UnsafeMutablePointer(mutating: ""))
            return IOReportProbeResult(dlopenOK: false, missingSymbols: [], groupFound: false,
                                       channels: [], note: "dlopen 失败：\(err)")
        }

        // ── 逐个 dlsym，缺哪个就记下来（不猜、不慌） ──
        var missing: [String] = []
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else {
                missing.append(name)
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }

        typealias FnCopyChannelsInGroup =
            @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
        typealias FnCreateSubscription =
            @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                            UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64,
                            CFTypeRef?) -> Unmanaged<AnyObject>?
        typealias FnCreateSamples =
            @convention(c) (Unmanaged<AnyObject>?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        typealias FnCreateSamplesDelta =
            @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        typealias FnChannelGetName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        typealias FnChannelGetSubGroup = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        typealias FnSimpleGetInteger = @convention(c) (CFDictionary, Int32) -> Int64
        typealias FnStateGetCount = @convention(c) (CFDictionary) -> Int32
        typealias FnStateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

        guard let copyChannels = sym("IOReportCopyChannelsInGroup", FnCopyChannelsInGroup.self),
              let createSub    = sym("IOReportCreateSubscription", FnCreateSubscription.self),
              let createSamples = sym("IOReportCreateSamples", FnCreateSamples.self),
              let createDelta  = sym("IOReportCreateSamplesDelta", FnCreateSamplesDelta.self),
              let chName       = sym("IOReportChannelGetChannelName", FnChannelGetName.self),
              let chSubgroup   = sym("IOReportChannelGetSubGroup", FnChannelGetSubGroup.self),
              let simpleGet    = sym("IOReportSimpleGetIntegerValue", FnSimpleGetInteger.self),
              let stateCount   = sym("IOReportStateGetCount", FnStateGetCount.self),
              let stateResid   = sym("IOReportStateGetResidency", FnStateGetResidency.self)
        else {
            return IOReportProbeResult(dlopenOK: true, missingSymbols: missing, groupFound: false,
                                       channels: [], note: "缺少符号，无法继续")
        }

        // ── 取通道 ──
        guard let channelsUnmanaged = copyChannels(groupName, nil, 0, 0, 0) else {
            return IOReportProbeResult(dlopenOK: true, missingSymbols: missing, groupFound: false,
                                       channels: [], note: "组 \"Energy Model\" 取不到通道（可能该平台没有这个组）")
        }
        let desired = channelsUnmanaged.takeRetainedValue()
        // 组取到了不代表里面有东西 —— 先把通道数记下来，这是判断「平台是否暴露」
        // 与「沙箱是否拦截」的分水岭。
        let desiredCount = CFDictionaryGetCount(desired)

        // ── 订阅 ──
        //
        // macOS 上的惯例是把第一个参数传 NULL，但在 iOS 上这样拿不到订阅：
        // 从 IORegistry 的 AGXAccelerator 节点可以看到 "Energy Model" 组里确实有
        // "GPU Energy" 通道，说明通道存在，失败的是订阅这一环。
        // 因此这里额外尝试：用 IOServiceGetMatchingService("AGXAccelerator")
        // 拿到服务句柄，把它作为第一个参数再订一次。
        typealias FnIOServiceMatching = @convention(c) (UnsafePointer<CChar>) -> CFMutableDictionary?
        typealias FnIOServiceGetMatching = @convention(c) (UInt32, CFMutableDictionary?) -> UInt32

        var subbed: Unmanaged<CFMutableDictionary>?
        var sub = createSub(nil, desired, &subbed, 0, nil)
        var viaService: UInt32 = 0
        if sub == nil,
           let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
           let pMatch = dlsym(iokit, "IOServiceMatching"),
           let pGet   = dlsym(iokit, "IOServiceGetMatchingService") {
            let matchFn = unsafeBitCast(pMatch, to: FnIOServiceMatching.self)
            let getFn   = unsafeBitCast(pGet,   to: FnIOServiceGetMatching.self)
            viaService = "AGXAccelerator".withCString { name in
                let matching = matchFn(name)
                return getFn(0, matching)
            }
            if viaService != 0, let svcPtr = UnsafeMutableRawPointer(bitPattern: Int(viaService)) {
                sub = createSub(svcPtr, desired, &subbed, 0, nil)
            }
        }

        guard let sub = sub,
              let subbedChannels = subbed?.takeRetainedValue() else {
            return IOReportProbeResult(dlopenOK: true, missingSymbols: missing, groupFound: true,
                                       channels: [],
                                       note: "订阅失败；通道数 = \(desiredCount)，"
                                           + "AGXAccelerator 服务句柄 = \(viaService)")
        }

        // ── 两次采样求差 ──
        guard let s1 = createSamples(sub, subbedChannels, nil)?.takeRetainedValue() else {
            return IOReportProbeResult(dlopenOK: true, missingSymbols: missing, groupFound: true,
                                       channels: [], note: "第一次采样失败")
        }
        Thread.sleep(forTimeInterval: max(0.2, seconds))
        guard let s2 = createSamples(sub, subbedChannels, nil)?.takeRetainedValue() else {
            return IOReportProbeResult(dlopenOK: true, missingSymbols: missing, groupFound: true,
                                       channels: [], note: "第二次采样失败")
        }
        guard let deltaDict = createDelta(s1, s2, nil)?.takeRetainedValue() else {
            return IOReportProbeResult(dlopenOK: true, missingSymbols: missing, groupFound: true,
                                       channels: [], note: "求差失败")
        }

        // ── 遍历 delta 字典：key = 通道描述，value = 该通道的样本 ──
        let count = CFDictionaryGetCount(deltaDict)
        var keyPtrs = [UnsafeRawPointer?](repeating: nil, count: count)
        var valPtrs = [UnsafeRawPointer?](repeating: nil, count: count)
        CFDictionaryGetKeysAndValues(deltaDict, &keyPtrs, &valPtrs)

        var out: [IOReportDomainSample] = []
        out.reserveCapacity(count)

        for i in 0..<count {
            guard let kp = keyPtrs[i], let vp = valPtrs[i] else { continue }
            // 两个指针都是 CF 对象，按非拥有引用取出（字典持有它们）
            let chDict = Unmanaged<CFDictionary>.fromOpaque(kp).takeUnretainedValue()
            let sampleDict = Unmanaged<CFDictionary>.fromOpaque(vp).takeUnretainedValue()

            let name = (chName(chDict)?.takeUnretainedValue() as String?) ?? "?"
            let subg = (chSubgroup(chDict)?.takeUnretainedValue() as String?) ?? ""

            // 通道分 Simple（单值）和 State（多状态驻留）两类，取值方式不同。
            var v = simpleGet(sampleDict, 0)
            if v == 0 {
                let n = stateCount(sampleDict)
                if n > 0 {
                    var sum: Int64 = 0
                    for j in 0..<n { sum += stateResid(sampleDict, j) }
                    v = sum
                }
            }
            out.append(IOReportDomainSample(channelName: name, subgroup: subg, delta: v))
        }

        out.sort { $0.channelName < $1.channelName }
        return IOReportProbeResult(dlopenOK: true, missingSymbols: missing, groupFound: true,
                                   channels: out, note: "成功，\(count) 个通道")
    }

    /// 全量通道普查：`IOReportCopyAllChannels` 拿到平台上**所有**通道，
    /// 按 group 归类计数。
    ///
    /// 为什么需要：`IOReportCopyChannelsInGroup("Energy Model")` 在 iOS 上可能
    /// 返回一个**空字典**（组名对但没通道），也可能被沙箱挡住订阅。两者现象不同、
    /// 对策也不同 —— 普查能一眼分开：
    ///   - 普查里根本没有 "Energy Model" → 这个平台不暴露该组，路断了
    ///   - 有且通道数 > 0，但订阅仍失败 → 是沙箱/entitlement 限制
    public static func surveyGroups() -> [String: Int] {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return [:] }

        typealias FnCopyAll = @convention(c) (UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
        typealias FnGetGroup = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

        guard let pAll = dlsym(handle, "IOReportCopyAllChannels"),
              let pGroup = dlsym(handle, "IOReportChannelGetGroup") else { return [:] }
        let copyAll = unsafeBitCast(pAll, to: FnCopyAll.self)
        let getGroup = unsafeBitCast(pGroup, to: FnGetGroup.self)

        guard let all = copyAll(0, 0, 0)?.takeRetainedValue() else { return [:] }

        let n = CFDictionaryGetCount(all)
        var keyPtrs = [UnsafeRawPointer?](repeating: nil, count: n)
        var valPtrs = [UnsafeRawPointer?](repeating: nil, count: n)
        CFDictionaryGetKeysAndValues(all, &keyPtrs, &valPtrs)

        var tally: [String: Int] = [:]
        for i in 0..<n {
            guard let kp = keyPtrs[i] else { continue }
            let ch = Unmanaged<CFDictionary>.fromOpaque(kp).takeUnretainedValue()
            let g = (getGroup(ch)?.takeUnretainedValue() as String?) ?? "?"
            tally[g, default: 0] += 1
        }
        return tally
    }

    /// 打一行（或多行）诊断日志。
    public static func debugLines(_ r: IOReportProbeResult, seconds: Double) -> [String] {
        var lines: [String] = []
        lines.append("[IOREPORT] dlopen=\(r.dlopenOK) group=\(r.groupFound) "
                     + "channels=\(r.channels.count) note=\(r.note)")
        if !r.missingSymbols.isEmpty {
            lines.append("[IOREPORT] 缺失符号：\(r.missingSymbols.joined(separator: ", "))")
        }
        for c in r.channels {
            let sg = c.subgroup.isEmpty ? "-" : c.subgroup
            lines.append("[IOREPORT]   \(c.channelName)  Δ=\(c.delta)  (\(String(format: "%.2f", seconds))s, 子组=\(sg))")
        }
        return lines
    }
}
