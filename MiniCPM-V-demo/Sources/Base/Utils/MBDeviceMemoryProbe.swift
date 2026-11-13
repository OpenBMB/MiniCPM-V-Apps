//
//  MBDeviceMemoryProbe.swift
//  MiniCPM-V-demo
//
//  Per-device n_ubatch / n_ctx tier selection.
//  The tiers are sized so that the GPU compute buffer and the KV cache fit the
//  memory the OS gives this app on each device class.
//

import Foundation
import Metal

#if canImport(Darwin)
import Darwin
#endif

@objc public final class MBDeviceMemoryProbe: NSObject {

    /// Coarse tier categories we map every device into.  Names are device-agnostic
    /// (we don't say "iPhone 12" anywhere) so the same enum is reusable on iPad,
    /// macOS Designed-for-iPad, and visionOS.
    @objc public enum Tier: Int {
        /// < ~1.0 GB free for this app — base 4 GB iPhones (12 / 13 / SE3) where
        /// jetsam threshold is tight.  We pick the smallest viable n_ubatch.
        case tiny = 0
        /// ~1.0–2.0 GB free — 6 GB iPhones (14 non-Pro / 15 / 16 non-Pro).
        case small = 1
        /// ~2.0–3.5 GB free — 8 GB iPhone Pro / iPad Pro M-series in baseline RAM.
        case medium = 2
        /// >= 3.5 GB free — Pro / Max with 12+ GB RAM, Macs running iOS app.
        case large = 3

        public var displayName: String {
            switch self {
            case .tiny:   return "tiny"
            case .small:  return "small"
            case .medium: return "medium"
            case .large:  return "large"
            }
        }

        /// Recommended `n_ubatch`.  Calibrated against MiniCPM-V 4.6 Q4_K_M
        /// memory measurements (see file header).
        public var recommendedUbatch: Int {
            switch self {
            case .tiny:   return 128   // ~120 MiB compute
            case .small:  return 256   // ~243 MiB
            case .medium: return 512   // ~487 MiB
            case .large:  return 1024  // ~970 MiB; n_ubatch=2048 saved no extra time, just memory
            }
        }

        /// Recommended `n_ctx` (tokens). V4.6 KV is 12 KiB/token (6 attn layers only).
        /// 8K 是下限（要装下 64 帧视频轮）；每档翻倍。见文档 §2。
        public var recommendedNCtx: Int {
            switch self {
            case .tiny:   return 8192    //  ~96 MiB KV
            case .small:  return 16384   // ~192 MiB KV
            case .medium: return 32768   // ~384 MiB KV
            case .large:  return 32768   // 32K is the sweet spot — beyond this attention O(N²) dominates without TPS win
            }
        }

        /// 恒返回 -1：实测该旋钮对 minicpmv 无效（切片数被 mtmd-image.cpp 硬编码为 9），
        /// 且 master 的纯 ggml 视觉编码器在所有切片间复用同一块 compute buffer，
        /// 多片只是「更多次 dispatch」，不是更多内存。见文档 §3。
        public var recommendedImageMaxTokens: Int {
            switch self {
            case .tiny:   return -1
            case .small:  return -1
            case .medium: return -1
            case .large:  return -1
            }
        }
    }

    /// True iff running inside an iOS / iPadOS Simulator.
    /// 用于跳过模拟器无法服务的 GPU 路径（mmproj 加载会 SIGTRAP）。生产构建绝不能开。
    @objc public static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    /// Bytes the OS believes this process can still allocate before jetsam
    /// kicks in.  iOS / iPadOS / visionOS only; returns 0 elsewhere.
    @objc public static var availableProcessBytes: UInt64 {
        #if canImport(Darwin) && (os(iOS) || os(visionOS))
        if #available(iOS 13.0, visionOS 1.0, *) {
            return UInt64(os_proc_available_memory())
        }
        #endif
        return 0
    }

    /// 本进程当前的实际物理占用（bytes）。用 `task_info(TASK_VM_INFO)` 拿
    /// `phys_footprint` —— 这是 jetsam 判定用的那个数，比 `resident_size` 更贴近
    /// 真实压力（含 GPU 共享内存的匿名页）。
    ///
    /// 为什么需要它：`os_proc_available_memory()` 只告诉我们「还能分配多少」，
    /// 但要做内存预算（比如 bank 能扩到多大），必须知道**当前已经占了多少**。
    @objc public static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    /// 一行内存报告，用于基准/诊断日志。
    @objc public static func memoryReport(_ tag: String) -> String {
        let phys    = physicalBytes
        let avail   = availableProcessBytes
        let foot    = footprintBytes
        func gib(_ b: UInt64) -> String { String(format: "%.2f", Double(b) / 1073741824.0) }
        let metal: UInt64 = {
            if let d = MTLCreateSystemDefaultDevice() {
                return UInt64(d.currentAllocatedSize)
            }
            return 0
        }()
        return String(format: "[MEM] %@ phys=%@ GiB footprint=%@ GiB available=%@ GiB metal=%@ GiB",
                      tag, gib(phys), gib(foot), gib(avail), gib(metal))
    }

    /// 物理 RAM of the device in bytes.  Cross-platform.
    @objc public static var physicalBytes: UInt64 {
        return ProcessInfo.processInfo.physicalMemory
    }

    /// Picked tier for this device, computed once at first access and cached.
    /// We deliberately freeze the tier at startup — re-probing later in the
    /// session would race with whatever else the app is doing and produce
    /// jittery readings; users would rather the model behave predictably.
    @objc public static let currentTier: Tier = computeInitialTier()

    /// Convenience wrapper: the n_ubatch we want MTMDParams.toCParams() to use.
    @objc public static var recommendedUbatch: Int { currentTier.recommendedUbatch }

    /// Convenience: tier-recommended `n_ctx` for the LLM context.
    /// See `Tier.recommendedNCtx` for tier→value table and tradeoff notes.
    @objc public static var recommendedNCtx: Int { currentTier.recommendedNCtx }

    private static func computeInitialTier() -> Tier {
        let avail = availableProcessBytes
        let phys  = physicalBytes
        let tier: Tier

        // Prefer `os_proc_available_memory` when we have it (iOS / visionOS),
        // since it knows about jetsam's per-app cap.  Fall back to physical
        // RAM (macOS / simulator) using rough Apple "app gets ~50% of RAM"
        // heuristic so the tier still makes sense in dev builds.
        if avail > 0 {
            switch avail {
            case ..<(1_000 * 1024 * 1024):     tier = .tiny      // < 1.0 GB
            case ..<(2_000 * 1024 * 1024):     tier = .small     // < 2.0 GB
            case ..<(3_500 * 1024 * 1024):     tier = .medium    // < 3.5 GB
            default:                            tier = .large     // >= 3.5 GB
            }
        } else if phys > 0 {
            // ~50% of physical RAM is a safe approximation of the per-app cap
            // on Apple platforms before jetsam considers the app a candidate.
            let est = phys / 2
            switch est {
            case ..<(1_000 * 1024 * 1024):     tier = .tiny
            case ..<(2_000 * 1024 * 1024):     tier = .small
            case ..<(3_500 * 1024 * 1024):     tier = .medium
            default:                            tier = .large
            }
        } else {
            tier = .small
        }

        // Always log; this is cheap and pays for itself the first time we
        // get a TestFlight crash report from a device with funny RAM.
        //
        // Avoid String(format:) here — iOS 26 enforces a strict runtime
        // check that flags `%d` against Swift's 64-bit `Int`, and the
        // resulting console noise drowns out the actual probe value.
        // Plain interpolation + a tiny fmt2 helper keeps the output clean.
        let physGB  = Double(phys)  / 1_073_741_824
        let availGB = Double(avail) / 1_073_741_824
        let fmt2: (Double) -> String = { String(format: "%.2f", $0) }
        print("[MBDeviceMemoryProbe] phys=\(fmt2(physGB)) GB available=\(fmt2(availGB)) GB → tier=\(tier.displayName) (n_ubatch=\(tier.recommendedUbatch))")
        return tier
    }

    // ── 最大可用内存实测 ──────────────────────────────────────────────────
    //
    // 分块 malloc 后逐字节写入（只分配不写不计入 phys_footprint），每块记录 footprint
    // 与可用量，低于安全线即停并全部释放。用 malloc 而非 MTLBuffer 是为了不依赖 Metal。

    /// 一次实测的结果。
    public struct MemoryMeasurement {
        public let physicalBytes: UInt64
        public let baselineFootprint: UInt64
        public let baselineAvailable: UInt64
        public let peakFootprint: UInt64
        public let minAvailable: UInt64
        public let allocatedBytes: UInt64
        public let stopReason: String
        /// 每块的增长曲线。
        public let trace: [String]
        /// 上一次探测是否没跑完（被系统杀掉）。
        public let previousRunCrashed: Bool
        /// 上次被杀时已分配到的字节数，即真实上限的下界。
        public let previousCrashBytes: UInt64

        public var report: String {
            let mb: (UInt64) -> String = { String(format: "%.0f MiB", Double($0) / 1_048_576.0) }
            let gb: (UInt64) -> String = { String(format: "%.2f GiB", Double($0) / 1_073_741_824.0) }
            var s = ""
            s += "物理内存        \(gb(physicalBytes))\n"
            s += "起始 footprint  \(mb(baselineFootprint))\n"
            s += "起始可用        \(gb(baselineAvailable))\n"
            s += "─────────────────────────\n"
            s += "本次额外分配    \(gb(allocatedBytes))\n"
            s += "峰值 footprint  \(gb(peakFootprint))\n"
            s += "剩余可用(最低)  \(gb(minAvailable))\n"
            s += "停止原因        \(stopReason)\n"
            s += "─────────────────────────\n"
            // 两个口径应互相接近：footprint 增量 vs 可用量降幅。
            s += "实测可吃下      \(gb(peakFootprint - baselineFootprint))\n"
            s += "OS 口径消耗     \(gb(baselineAvailable > minAvailable ? baselineAvailable - minAvailable : 0))\n"
            s += "峰值占物理      \(String(format: "%.1f%%", 100.0 * Double(peakFootprint) / Double(max(physicalBytes, 1))))\n"
            if previousRunCrashed {
                s += "─────────────────────────\n"
                s += "上次探测在 \(gb(previousCrashBytes)) 处被杀，真实上限 ≥ 该值\n"
            }
            return s
        }
    }

    private static let memProbeLastKey  = "moe_memprobe_last_bytes"
    private static let memProbeCleanKey = "moe_memprobe_clean"

    /// 上次探测留下的记录。返回 (已分配字节, 是否跑完)。
    public static func lastMemProbeState() -> (bytes: UInt64, clean: Bool) {
        let ud = UserDefaults.standard
        return (UInt64(ud.integer(forKey: memProbeLastKey)), ud.bool(forKey: memProbeCleanKey))
    }

    /// 实测最大可用内存。必须在后台线程调用。
    /// 每分配一块就写盘进度，正常收尾才置 clean=true —— 进程被杀后下次能读到
    /// 「上次死在哪里」并把本次上限夹在其下，一次被杀也变成有效数据。
    public static func measureMaxUsable(chunkMiB: Int = 256,
                                        safetyMiB: Int = 512,
                                        hardCapMiB: Int? = nil,
                                        progress: ((String) -> Void)? = nil) -> MemoryMeasurement {
        let chunk = UInt64(max(1, chunkMiB)) * 1_048_576
        let safety = UInt64(max(1, safetyMiB)) * 1_048_576
        let phys = physicalBytes
        let ud = UserDefaults.standard

        let prevBytes = UInt64(ud.integer(forKey: memProbeLastKey))
        let prevClean = ud.bool(forKey: memProbeCleanKey)
        let hadHistory = prevBytes > 0
        let prevCrashed = hadHistory && !prevClean

        // 抹掉「跑完了」标记；若此后进程被杀，下次即可看出来。
        ud.set(false, forKey: memProbeCleanKey)
        ud.set(0, forKey: memProbeLastKey)

        // 上次被杀过就夹到那个值之下。
        let cap: UInt64 = {
            if let h = hardCapMiB { return UInt64(max(1, h)) * 1_048_576 }
            if prevCrashed { return prevBytes }
            return phys
        }()

        let baseFoot = footprintBytes
        let baseAvail = availableProcessBytes
        var peakFoot = baseFoot
        var minAvail = baseAvail
        var allocated: UInt64 = 0
        var reason = "循环结束"
        var blocks: [UnsafeMutableRawPointer] = []
        var trace: [String] = []

        let mb: (UInt64) -> String = { String(format: "%.0f", Double($0) / 1_048_576.0) }

        while true {
            if allocated + chunk > cap {
                reason = prevCrashed
                    ? "已到上次被杀位置 \(mb(prevBytes)) MiB 之下，不再往上试"
                    : "达到上限 \(mb(cap)) MiB"
                break
            }
            if availableProcessBytes > 0 && availableProcessBytes < safety {
                reason = "剩余可用 \(mb(availableProcessBytes)) MiB < 安全线 \(safetyMiB) MiB"
                break
            }
            // 只 malloc 不写不计入 footprint，所以要 memset 逐页提交。
            guard let p = malloc(Int(chunk)) else {
                reason = "malloc 失败（连续 \(mb(allocated)) MiB 之后）"
                break
            }
            memset(p, 0xA5, Int(chunk))
            blocks.append(p)
            allocated += chunk

            let f = footprintBytes
            peakFoot = max(peakFoot, f)
            let a = availableProcessBytes
            if a > 0 { minAvail = min(minAvail, a) }

            // 逐块落盘，被系统杀掉后也能拿到进度。
            ud.set(Int(allocated), forKey: memProbeLastKey)

            let line = String(format: "分配 %@ MiB → footprint %@ MiB / 可用 %@ MiB",
                              mb(allocated), mb(f), a > 0 ? mb(a) : "n/a")
            trace.append(line)
            progress?(line)

            // 可用量读不到时（非 iOS）靠 footprint 兜底。
            if availableProcessBytes == 0 && f > phys / 10 * 9 {
                reason = "footprint 已达物理内存 90%（可用量不可读）"
                break
            }
        }

        let result = MemoryMeasurement(
            physicalBytes: phys,
            baselineFootprint: baseFoot,
            baselineAvailable: baseAvail,
            peakFootprint: peakFoot,
            minAvailable: minAvail,
            allocatedBytes: allocated,
            stopReason: reason,
            trace: trace,
            previousRunCrashed: prevCrashed,
            previousCrashBytes: prevBytes)

        // 立刻还回去 —— 探测不能把内存留着。
        for p in blocks { free(p) }
        // 正常收尾：标记「跑完了」，下次不再当成被杀。
        ud.set(true, forKey: memProbeCleanKey)
        progress?("已释放 \(mb(allocated)) MiB")

        print("[MEMPROBE] \(result.report.replacingOccurrences(of: "\n", with: " | "))")
        return result
    }
}
