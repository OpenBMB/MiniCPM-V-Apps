//
//  MBDeviceMemoryProbe.swift
//  MiniCPM-V-demo
//
//  Pick a per-device n_ubatch tier so MiniCPM-V 4.6 doesn't get jetsam'd on
//  4 GB iPhones and doesn't leave perf on the table on 8 GB+ Pro / iPad.
//
//  Background: the GPU compute buffer of a llama_context is dominated by
//  `n_ubatch * vocab_size * sizeof(f32)` (output projection) plus per-ubatch
//  attention scratch.  On MiniCPM-V 4.6 (Qwen vocab ~150K) the measured
//  cost on Apple Silicon is roughly:
//
//      n_ubatch=2048 → ~1946 MiB MTL0 compute  (legacy demo default)
//      n_ubatch=1024 → ~970  MiB
//      n_ubatch= 512 → ~487  MiB
//      n_ubatch= 256 → ~243  MiB
//      n_ubatch= 128 → ~120  MiB
//
//  Speed is essentially flat across this range on A-series GPUs (decode is
//  bandwidth-bound, not compute-bound), so smaller n_ubatch is mostly a
//  memory-vs-prefill-overhead trade-off; we want to push it as low as a
//  given device's headroom allows.
//
//  iOS gives us two relevant numbers:
//
//    - `os_proc_available_memory()`  : how much MORE memory THIS process can
//                                      allocate before jetsam shows up.  Most
//                                      accurate predictor of "will V4.6 fit",
//                                      but only available on iOS / iPadOS / visionOS.
//    - `ProcessInfo.physicalMemory`  : total device RAM (in bytes).  Used as
//                                      a fallback (macOS / simulator) and a
//                                      sanity cross-check.
//
//  We log both at startup so support reports / TestFlight feedback can be
//  cross-referenced with the picked tier without needing the user to run
//  Xcode Instruments.
//

import Foundation

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

        /// Recommended `n_ctx` for the LLM context (in tokens).
        ///
        /// Each token of MiniCPM-V 4.6 KV cache is **12 KiB**:
        ///   - 24 layers, but only every 4th is full attention (24/4 = 6 attn layers,
        ///     the other 18 are SSM and DON'T scale with n_ctx)
        ///   - 6 attn × 2 (k+v) × 2 (n_head_kv, GQA) × 256 (head_dim) × 2 B (f16) = 12 KiB
        /// So the cost is exactly:
        ///
        ///   n_ctx=4096  →  48 MiB
        ///   n_ctx=8192  →  96 MiB
        ///   n_ctx=16384 → 192 MiB
        ///   n_ctx=32768 → 384 MiB
        ///   n_ctx=65536 → 768 MiB
        ///
        /// Tier choice tradeoffs:
        ///   - n_ctx must hold the worst-case prefill: V4.6 video path is 64 frames ×
        ///     ~64 visual tokens/frame = 4096 image tokens, plus the system + first
        ///     user turn + assistant prefix (~200 tokens), plus headroom for a couple
        ///     of follow-up turns.  Below ~6000 the video path is at risk of overflow.
        ///   - Each extra 4K of n_ctx costs +48 MiB MTL0 KV; on a 4 GiB iPhone whose
        ///     jetsam ceiling sits around 1.4 GiB, that pushes against the same budget
        ///     n_ubatch / mmproj working set already eats.
        ///   - Single-image / short-chat scenarios are insensitive to n_ctx, but very
        ///     long contexts push attention compute to O(N²) per token (FlashAttention
        ///     fixes the memory but not the FLOPs), making *late-frame* video prefill
        ///     visibly slower at 32K than at 8K.
        ///
        /// 8K is the floor (must hold a V4.6 video turn); we double per tier so a Pro
        /// device with plenty of headroom gets longer history without blowing budget.
        public var recommendedNCtx: Int {
            switch self {
            case .tiny:   return 8192    //  ~96 MiB KV
            case .small:  return 16384   // ~192 MiB KV
            case .medium: return 32768   // ~384 MiB KV
            case .large:  return 32768   // 32K is the sweet spot — beyond this attention O(N²) dominates without TPS win
            }
        }

        /// Recommended `image_max_tokens` for mtmd.  Returns -1 ("model
        /// default") on every tier — see explanation below.
        ///
        /// History: an earlier draft of this knob tried to cap MiniCPM-V's
        /// slice count on low-RAM devices (tiny=64 tokens → overview-only,
        /// small=256 → 2×2 grid).  When measured against a 3200×2400 image
        /// the cap had ZERO effect on minicpmv: bridge_test gave grid=3×3 =
        /// 10 slices regardless of image_max_tokens=-1 / 64 / 256.
        ///
        /// Root cause: master's mtmd-image.cpp:648 hard-codes
        ///     `const int max_slice_nums = 9;`
        /// for the minicpmv slicing path and never reads any
        /// `image_max_tokens`-derived value from `clip_ctx`.  The
        /// `image_max_tokens` knob *does* throttle the generic
        /// llava-uhd preprocess path (image_max_pixels → resize), but
        /// minicpmv has its own `get_slice_instructions` that directly
        /// looks at original_size and ignores image_max_pixels for the
        /// grid decision.
        ///
        /// Why we don't need it anyway: the old jetsam @ slice 5/6 was
        /// caused by the ex-CoreML path, where each slice triggered a
        /// fresh CoreML merger load + ANE/CPU staging buffers that did
        /// NOT get released between slices.  Master's pure ggml/Metal
        /// vision encoder reuses a single ~36 MiB CLIP compute buffer
        /// across all slices (verified in bridge_test) — multi-slice
        /// prefill is "more dispatches", not "more memory".
        ///
        /// We keep the knob plumbing in place so a future master PR that
        /// actually plumbs image_max_tokens into get_best_grid (the TODO
        /// comment in mtmd-image.cpp acknowledges this) can be picked up
        /// by switching these returns back from -1 to a tier-specific cap.
        public var recommendedImageMaxTokens: Int {
            switch self {
            case .tiny:   return -1
            case .small:  return -1
            case .medium: return -1
            case .large:  return -1
            }
        }
    }

    /// True iff we're running inside an iOS / iPadOS Simulator.
    ///
    /// Used to opt out of GPU paths that the Simulator's `MTLSimDevice` can't
    /// service — most notably mmproj load, which calls
    /// `[MTLSimDevice newBufferWithLength:...]` with ~1 GiB and trips
    /// `_xpc_api_misuse` (SIGTRAP) on the XPC shared-memory channel.  On a
    /// real iPhone / iPad the same code path uses the actual Metal driver
    /// and works fine, so this flag must NEVER be on in production builds.
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

    /// Physical RAM of the device in bytes.  Cross-platform.
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
}
