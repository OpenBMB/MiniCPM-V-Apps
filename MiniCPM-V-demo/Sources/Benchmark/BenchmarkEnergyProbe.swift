//
//  BenchmarkEnergyProbe.swift
//  MiniCPM-V-demo
//
//  任务 2 的能量采样器（V1）。
//
//  为什么存在：iOS **没有**公开 API 能读整机瓦特，但 libproc 的
//  `proc_pid_rusage()` 能给出**进程级能量（纳焦）**与**磁盘读写字节**，
//  `coalition_info_resource_usage()` 能给出 **GPU 时长**。数据来自
//  DPE（Digital Power Estimator），与 macOS `powermetrics` 同源 —— 也就是
//  苹果自家测功耗用的那套计数器。
//
//  这两个接口的好处：**纯软件、插电可用、旧 iOS（17.7）可用、无需越狱**。
//
//  ⚠️ 注意 `<libproc.h>` 在 iOS SDK 中**不可 import**（它只在 macOS SDK 里）。
//  所以这里用 `@_silgen_name` 直接链接 C 符号，并自行复刻结构体布局。
//  结构体字段与顺序对照 Apple OSS Distributions 的 `libproc.h`
//  （`rusage_info_v6`，别名 `rusage_info_current`，共 49 个字段）。
//
//  V1 的目的只有一个：**确认这些字段在 iOS 17.7 上真的非零递增。**
//  所以这里保留了大量原始诊断信息（返回码、按偏移量直读的交叉校验），
//  等 V2 确认口径后再精简。
//

import Foundation

// MARK: - C 符号直连

/// `int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer)`
@_silgen_name("proc_pid_rusage")
private func c_proc_pid_rusage(_ pid: Int32,
                               _ flavor: Int32,
                               _ buffer: UnsafeMutableRawPointer) -> Int32

/// `int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize)`
@_silgen_name("proc_pidinfo")
private func c_proc_pidinfo(_ pid: Int32,
                            _ flavor: Int32,
                            _ arg: UInt64,
                            _ buffer: UnsafeMutableRawPointer,
                            _ buffersize: Int32) -> Int32

/// `int coalition_info_resource_usage(uint64_t cid, struct coalition_resource_usage *cru, size_t sz)`
@_silgen_name("coalition_info_resource_usage")
private func c_coalition_info_resource_usage(_ cid: UInt64,
                                             _ cru: UnsafeMutableRawPointer,
                                             _ sz: Int) -> Int32

// MARK: - 常量（取自 libproc.h）

private let kRusageInfoCurrent: Int32 = 6      // RUSAGE_INFO_V6
private let kProcPidCoalitionInfo: Int32 = 20  // PROC_PIDCOALITIONINFO
private let kCoalitionTypeResource: Int = 0

// MARK: - 结构体复刻

/// `rusage_info_v6`：16 字节 uuid + 47 个 u64 + 9 个保留 u64 = 464 字节。
///
/// uuid 用两个 u64 拼出 16 字节，避免 Swift 里写 16 元组的丑陋写法，
/// 内存布局与 `uint8_t ri_uuid[16]` 完全一致。
private struct MBRusageInfoV6 {
    var ri_uuid_0: UInt64
    var ri_uuid_1: UInt64
    var ri_user_time: UInt64
    var ri_system_time: UInt64
    var ri_pkg_idle_wkups: UInt64
    var ri_interrupt_wkups: UInt64
    var ri_pageins: UInt64
    var ri_wired_size: UInt64
    var ri_resident_size: UInt64
    var ri_phys_footprint: UInt64
    var ri_proc_start_abstime: UInt64
    var ri_proc_exit_abstime: UInt64
    var ri_child_user_time: UInt64
    var ri_child_system_time: UInt64
    var ri_child_pkg_idle_wkups: UInt64
    var ri_child_interrupt_wkups: UInt64
    var ri_child_pageins: UInt64
    var ri_child_elapsed_abstime: UInt64
    var ri_diskio_bytesread: UInt64
    var ri_diskio_byteswritten: UInt64
    var ri_cpu_time_qos_default: UInt64
    var ri_cpu_time_qos_maintenance: UInt64
    var ri_cpu_time_qos_background: UInt64
    var ri_cpu_time_qos_utility: UInt64
    var ri_cpu_time_qos_legacy: UInt64
    var ri_cpu_time_qos_user_initiated: UInt64
    var ri_cpu_time_qos_user_interactive: UInt64
    var ri_billed_system_time: UInt64
    var ri_serviced_system_time: UInt64
    var ri_logical_writes: UInt64
    var ri_lifetime_max_phys_footprint: UInt64
    var ri_instructions: UInt64
    var ri_cycles: UInt64
    var ri_billed_energy: UInt64
    var ri_serviced_energy: UInt64
    var ri_interval_max_phys_footprint: UInt64
    var ri_runnable_time: UInt64
    var ri_flags: UInt64
    var ri_user_ptime: UInt64
    var ri_system_ptime: UInt64
    var ri_pinstructions: UInt64
    var ri_pcycles: UInt64
    var ri_energy_nj: UInt64
    var ri_penergy_nj: UInt64
    var ri_secure_time_in_system: UInt64
    var ri_secure_ptime_in_system: UInt64
    var ri_neural_footprint: UInt64
    var ri_lifetime_max_neural_footprint: UInt64
    var ri_interval_max_neural_footprint: UInt64
    var ri_reserved_0: UInt64
    var ri_reserved_1: UInt64
    var ri_reserved_2: UInt64
    var ri_reserved_3: UInt64
    var ri_reserved_4: UInt64
    var ri_reserved_5: UInt64
    var ri_reserved_6: UInt64
    var ri_reserved_7: UInt64
    var ri_reserved_8: UInt64
}

/// `struct proc_pidcoalitioninfo`。
///
/// `COALITION_NUM_TYPES` 在不同版本头文件里是 1 或 2，用 2 更稳：
/// 我们要的 `coalition_id[COALITION_TYPE_RESOURCE]` 是**第一个元素**，
/// 无论数组多长，偏移都是 0。
private struct MBProcPidCoalitionInfo {
    var coalition_id_0: UInt64
    var coalition_id_1: UInt64
    var reserved1: UInt64
    var reserved2: UInt64
    var reserved3: UInt64
}

/// `struct coalition_resource_usage`。`gpu_time` 是第 9 个字段（偏移 64 字节）。
private struct MBCoalitionResourceUsage {
    var tasks_started: UInt64
    var tasks_exited: UInt64
    var time_nonempty: UInt64
    var cpu_time: UInt64
    var interrupt_wakeups: UInt64
    var platform_idle_wakeups: UInt64
    var bytesread: UInt64
    var byteswritten: UInt64
    var gpu_time: UInt64
    var cpu_time_billed_to_me: UInt64
    var cpu_time_billed_to_others: UInt64
    var energy: UInt64
    var logical_immediate_writes: UInt64
    var logical_deferred_writes: UInt64
    var logical_invalidated_writes: UInt64
    var logical_metadata_writes: UInt64
    var logical_immediate_writes_to_external: UInt64
    var logical_deferred_writes_to_external: UInt64
    var logical_invalidated_writes_to_external: UInt64
    var logical_metadata_writes_to_external: UInt64
    var energy_billed_to_me: UInt64
    var energy_billed_to_others: UInt64
    var cpu_ptime: UInt64
    var cpu_time_eqos_len: UInt64
    var cpu_time_eqos_0: UInt64
    var cpu_time_eqos_1: UInt64
    var cpu_time_eqos_2: UInt64
    var cpu_time_eqos_3: UInt64
    var cpu_time_eqos_4: UInt64
    var cpu_time_eqos_5: UInt64
    var cpu_time_eqos_6: UInt64
    var cpu_instructions: UInt64
    var cpu_cycles: UInt64
    var fs_metadata_writes: UInt64
    var pm_writes: UInt64
}

// MARK: - 采样结果

public struct BenchmarkEnergySnapshot {

    // 返回码：诊断用。0 表示成功，负数/0 需排查。
    public let retRusage: Int32      // proc_pid_rusage 返回值
    public let retPidInfo: Int32     // proc_pidinfo 返回值
    public let retCoalition: Int32   // coalition_info_resource_usage 返回值

    // proc_pid_rusage
    public let energyNJ: UInt64          // ri_energy_nj        —— 进程能量，纳焦
    public let penergyNJ: UInt64         // ri_penergy_nj
    public let billedEnergy: UInt64      // ri_billed_energy
    public let servicedEnergy: UInt64    // ri_serviced_energy
    public let diskioBytesRead: UInt64   // ri_diskio_bytesread —— 磁盘读字节
    public let diskioBytesWritten: UInt64
    public let instructions: UInt64
    public let cycles: UInt64

    // 按偏移量直读的交叉校验：若与上面的具名读取不一致，说明结构体布局对不上。
    public let energyNJByOffset: UInt64
    public let diskioBytesReadByOffset: UInt64

    // coalition_info_resource_usage
    public let gpuTimeNs: UInt64         // GPU 时长，纳秒
    public let coalEnergy: UInt64
    public let coalBytesRead: UInt64
    public let coalBytesWritten: UInt64
    public let energyBilledToMe: UInt64
    public let energyBilledToOthers: UInt64
    public let cpuInstructions: UInt64
    public let cpuCycles: UInt64

    public var isUsable: Bool { retRusage > 0 }

    /// 两帧之间的增量。所有能量/字节字段都是累计值，差值才有意义。
    public func delta(since other: BenchmarkEnergySnapshot) -> [String: Int64] {
        return [
            "energyNJ":           Self.d(energyNJ, other.energyNJ),
            "penergyNJ":          Self.d(penergyNJ, other.penergyNJ),
            "billedEnergy":       Self.d(billedEnergy, other.billedEnergy),
            "servicedEnergy":     Self.d(servicedEnergy, other.servicedEnergy),
            "diskioBytesRead":    Self.d(diskioBytesRead, other.diskioBytesRead),
            "diskioBytesWritten": Self.d(diskioBytesWritten, other.diskioBytesWritten),
            "instructions":       Self.d(instructions, other.instructions),
            "cycles":             Self.d(cycles, other.cycles),
            "gpuTimeNs":          Self.d(gpuTimeNs, other.gpuTimeNs),
            "coalEnergy":         Self.d(coalEnergy, other.coalEnergy),
            "coalBytesRead":      Self.d(coalBytesRead, other.coalBytesRead),
            "coalBytesWritten":   Self.d(coalBytesWritten, other.coalBytesWritten),
            "energyBilledToMe":   Self.d(energyBilledToMe, other.energyBilledToMe),
            "energyBilledToOthers": Self.d(energyBilledToOthers, other.energyBilledToOthers),
            "cpuInstructions":    Self.d(cpuInstructions, other.cpuInstructions),
            "cpuCycles":          Self.d(cpuCycles, other.cpuCycles)
        ]
    }

    /// 无符号累计值求差，按回绕处理（理论上不会，但别让异常值静默变成天文数字）。
    private static func d(_ a: UInt64, _ b: UInt64) -> Int64 {
        return a >= b ? Int64(a - b) : -Int64(b - a)
    }
}

// MARK: - 采样器

public enum BenchmarkEnergyProbe {

    /// 采一帧。只读本进程（`getpid()`），不需要任何特权。
    public static func take() -> BenchmarkEnergySnapshot {
        let pid = Int32(getpid())

        // ── proc_pid_rusage ──
        var ru = MBRusageInfoV6(
            ri_uuid_0: 0, ri_uuid_1: 0,
            ri_user_time: 0, ri_system_time: 0, ri_pkg_idle_wkups: 0,
            ri_interrupt_wkups: 0, ri_pageins: 0, ri_wired_size: 0,
            ri_resident_size: 0, ri_phys_footprint: 0, ri_proc_start_abstime: 0,
            ri_proc_exit_abstime: 0, ri_child_user_time: 0, ri_child_system_time: 0,
            ri_child_pkg_idle_wkups: 0, ri_child_interrupt_wkups: 0,
            ri_child_pageins: 0, ri_child_elapsed_abstime: 0,
            ri_diskio_bytesread: 0, ri_diskio_byteswritten: 0,
            ri_cpu_time_qos_default: 0, ri_cpu_time_qos_maintenance: 0,
            ri_cpu_time_qos_background: 0, ri_cpu_time_qos_utility: 0,
            ri_cpu_time_qos_legacy: 0, ri_cpu_time_qos_user_initiated: 0,
            ri_cpu_time_qos_user_interactive: 0, ri_billed_system_time: 0,
            ri_serviced_system_time: 0, ri_logical_writes: 0,
            ri_lifetime_max_phys_footprint: 0, ri_instructions: 0, ri_cycles: 0,
            ri_billed_energy: 0, ri_serviced_energy: 0,
            ri_interval_max_phys_footprint: 0, ri_runnable_time: 0, ri_flags: 0,
            ri_user_ptime: 0, ri_system_ptime: 0, ri_pinstructions: 0, ri_pcycles: 0,
            ri_energy_nj: 0, ri_penergy_nj: 0, ri_secure_time_in_system: 0,
            ri_secure_ptime_in_system: 0, ri_neural_footprint: 0,
            ri_lifetime_max_neural_footprint: 0, ri_interval_max_neural_footprint: 0,
            ri_reserved_0: 0, ri_reserved_1: 0, ri_reserved_2: 0, ri_reserved_3: 0,
            ri_reserved_4: 0, ri_reserved_5: 0, ri_reserved_6: 0, ri_reserved_7: 0,
            ri_reserved_8: 0
        )
        let sizeRU = Int32(MemoryLayout<MBRusageInfoV6>.size)

        let retRusage = withUnsafeMutableBytes(of: &ru) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return c_proc_pid_rusage(pid, kRusageInfoCurrent, base)
        }

        // 按偏移量直读，交叉校验布局
        var energyByOffset: UInt64 = 0
        var bytesReadByOffset: UInt64 = 0
        withUnsafeBytes(of: &ru) { raw in
            guard let base = raw.baseAddress else { return }
            // ri_energy_nj 是 uuid 之后的第 41 个 u64 → 16 + 40*8 = 336
            energyByOffset = base.loadUnaligned(fromByteOffset: 336, as: UInt64.self)
            // ri_diskio_bytesread 是第 17 个 u64 → 16 + 16*8 = 144
            bytesReadByOffset = base.loadUnaligned(fromByteOffset: 144, as: UInt64.self)
        }

        // ── coalition ──
        var ci = MBProcPidCoalitionInfo(
            coalition_id_0: 0, coalition_id_1: 0,
            reserved1: 0, reserved2: 0, reserved3: 0
        )
        let retPidInfo = withUnsafeMutableBytes(of: &ci) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return c_proc_pidinfo(pid, kProcPidCoalitionInfo, 0, base,
                                  Int32(MemoryLayout<MBProcPidCoalitionInfo>.size))
        }

        var cru = MBCoalitionResourceUsage(
            tasks_started: 0, tasks_exited: 0, time_nonempty: 0, cpu_time: 0,
            interrupt_wakeups: 0, platform_idle_wakeups: 0, bytesread: 0,
            byteswritten: 0, gpu_time: 0, cpu_time_billed_to_me: 0,
            cpu_time_billed_to_others: 0, energy: 0, logical_immediate_writes: 0,
            logical_deferred_writes: 0, logical_invalidated_writes: 0,
            logical_metadata_writes: 0, logical_immediate_writes_to_external: 0,
            logical_deferred_writes_to_external: 0,
            logical_invalidated_writes_to_external: 0,
            logical_metadata_writes_to_external: 0, energy_billed_to_me: 0,
            energy_billed_to_others: 0, cpu_ptime: 0, cpu_time_eqos_len: 0,
            cpu_time_eqos_0: 0, cpu_time_eqos_1: 0, cpu_time_eqos_2: 0,
            cpu_time_eqos_3: 0, cpu_time_eqos_4: 0, cpu_time_eqos_5: 0,
            cpu_time_eqos_6: 0, cpu_instructions: 0, cpu_cycles: 0,
            fs_metadata_writes: 0, pm_writes: 0
        )

        var retCoalition: Int32 = -1
        if retPidInfo > 0, ci.coalition_id_0 != 0 {
            retCoalition = withUnsafeMutableBytes(of: &cru) { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return c_coalition_info_resource_usage(ci.coalition_id_0, base,
                                                       MemoryLayout<MBCoalitionResourceUsage>.size)
            }
        }

        return BenchmarkEnergySnapshot(
            retRusage: retRusage,
            retPidInfo: retPidInfo,
            retCoalition: retCoalition,
            energyNJ: ru.ri_energy_nj,
            penergyNJ: ru.ri_penergy_nj,
            billedEnergy: ru.ri_billed_energy,
            servicedEnergy: ru.ri_serviced_energy,
            diskioBytesRead: ru.ri_diskio_bytesread,
            diskioBytesWritten: ru.ri_diskio_byteswritten,
            instructions: ru.ri_instructions,
            cycles: ru.ri_cycles,
            energyNJByOffset: energyByOffset,
            diskioBytesReadByOffset: bytesReadByOffset,
            gpuTimeNs: cru.gpu_time,
            coalEnergy: cru.energy,
            coalBytesRead: cru.bytesread,
            coalBytesWritten: cru.byteswritten,
            energyBilledToMe: cru.energy_billed_to_me,
            energyBilledToOthers: cru.energy_billed_to_others,
            cpuInstructions: cru.cpu_instructions,
            cpuCycles: cru.cpu_cycles
        )
    }

    /// V1 诊断用：把原始值和布局校验结果打成一行。
    ///
    /// `layoutOK` 很关键：它比对「具名读取」与「按偏移量直读」是否一致。
    /// 若 false，说明我们复刻的 `rusage_info_v6` 布局与系统不一致，
    /// 后面所有数都不能信 —— 那时必须先修结构体，不要继续往下做。
    public static func debugLine(_ tag: String, _ s: BenchmarkEnergySnapshot) -> String {
        let layoutOK = (s.energyNJ == s.energyNJByOffset)
                    && (s.diskioBytesRead == s.diskioBytesReadByOffset)
        return """
        [ENERGY] \(tag) ret(rusage/pidinfo/coalition)=\(s.retRusage)/\(s.retPidInfo)/\(s.retCoalition) \
        layoutOK=\(layoutOK) energyNJ=\(s.energyNJ) penergyNJ=\(s.penergyNJ) \
        billedE=\(s.billedEnergy) servicedE=\(s.servicedEnergy) \
        diskRead=\(s.diskioBytesRead) diskWrite=\(s.diskioBytesWritten) \
        gpuTimeNs=\(s.gpuTimeNs) coalEnergy=\(s.coalEnergy) \
        coalRead=\(s.coalBytesRead) coalBilledMe=\(s.energyBilledToMe) \
        instr=\(s.instructions) cycles=\(s.cycles)
        """
    }

    /// V1 诊断用：两帧之间的增量，一行。
    ///
    /// 能量单位纳焦（nJ），1 J = 1e9 nJ。给焦耳换算方便肉眼判断量级。
    public static func debugDeltaLine(_ before: BenchmarkEnergySnapshot,
                                      _ after: BenchmarkEnergySnapshot) -> String {
        let d = after.delta(since: before)
        func v(_ k: String) -> Int64 { d[k] ?? 0 }
        let eJ = Double(v("energyNJ")) / 1e9
        let peJ = Double(v("penergyNJ")) / 1e9
        let coalJ = Double(v("coalEnergy")) / 1e9
        let mbRead = Double(v("diskioBytesRead")) / 1024.0 / 1024.0
        let gpuMs = Double(v("gpuTimeNs")) / 1e6
        return String(
            format: "[ENERGY] delta energyNJ=%lld (%.3f J) penergyNJ=%lld (%.3f J) "
                  + "billedE=%lld servicedE=%lld diskRead=%lld (%.1f MiB) diskWrite=%lld "
                  + "gpuTimeNs=%lld (%.1f ms) coalEnergy=%lld (%.3f J) coalRead=%lld "
                  + "coalWrite=%lld coalBilledMe=%lld coalBilledOthers=%lld "
                  + "instr=%lld cycles=%lld",
            v("energyNJ"), eJ, v("penergyNJ"), peJ,
            v("billedEnergy"), v("servicedEnergy"),
            v("diskioBytesRead"), mbRead, v("diskioBytesWritten"),
            v("gpuTimeNs"), gpuMs, v("coalEnergy"), coalJ,
            v("coalBytesRead"), v("coalBytesWritten"),
            v("energyBilledToMe"), v("energyBilledToOthers"),
            v("instructions"), v("cycles")
        )
    }

    /// 单个阶段的增量，一行。用于把一条 case 拆成「图像+预热 / prefill / decode」三段。
    ///
    /// 单位提示：`cpuEnergy` 是 **CPU 侧**能量（见 `debugDeltaLine` 的口径说明），
    /// 不含 GPU / 屏幕 / NAND。GPU 只能给时长（`gpuMs`），给不了能量。
    public static func debugPhaseLine(_ name: String,
                                      _ before: BenchmarkEnergySnapshot,
                                      _ after: BenchmarkEnergySnapshot) -> String {
        let d = after.delta(since: before)
        func v(_ k: String) -> Int64 { d[k] ?? 0 }
        return String(
            format: "[ENERGY] phase %@: cpuEnergy=%.4f J | diskRead=%.1f MiB | "
                  + "gpuMs=%.1f | cpuCycles=%.2f G | instr=%.2f G",
            name,
            Double(v("energyNJ")) / 1e9,
            Double(v("diskioBytesRead")) / 1048576.0,
            Double(v("gpuTimeNs")) / 1e6,
            Double(v("cycles")) / 1e9,
            Double(v("instructions")) / 1e9
        )
    }
}
