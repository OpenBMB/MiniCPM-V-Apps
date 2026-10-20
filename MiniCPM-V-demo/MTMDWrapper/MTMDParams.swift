//
//  MTMDParams.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation
import llama

/// MTMD 参数配置
@frozen public struct MTMDParams: Sendable {

    /// 模型路径
    public let modelPath: String

    /// 多模态投影模型路径
    public let mmprojPath: String

    /// 预测长度
    public let nPredict: Int

    /// 上下文长度
    public let nCtx: Int

    /// 线程数
    public let nThreads: Int

    /// 温度参数
    public let temperature: Float

    /// 是否使用 GPU
    public let useGPU: Bool

    /// 多模态投影是否使用 GPU
    public let mmprojUseGPU: Bool

    /// 是否预热
    public let warmup: Bool

    /// llama_context 的 physical batch（n_ubatch）。
    ///
    /// 0 = 沿用 native bridge 内部默认（当前 512）；> 0 则覆盖。建议由调用方
    /// 通过 `MBDeviceMemoryProbe.recommendedUbatch` 按机型挑档：
    ///
    ///    tier=tiny   n_ubatch=128  → ~120 MiB MTL0 compute（4 GB iPhone）
    ///    tier=small  n_ubatch=256  → ~243 MiB           （6 GB iPhone）
    ///    tier=medium n_ubatch=512  → ~487 MiB           （8 GB iPhone Pro / iPad）
    ///    tier=large  n_ubatch=1024 → ~970 MiB           （12+ GB Pro / Mac）
    ///
    /// 老的 mtmd-ios.cpp 里 hardcoded n_ubatch=2048（~1.95 GB compute），是
    /// "新机器跑得飞快但旧机器闪退" 的根因。
    public let nUbatch: Int

    /// 单张图最大切片数（仅对 llava-uhd 风格模型生效，例如 MiniCPM-V）。
    /// - `-1`：按模型默认（MiniCPM-V 当前 9 片）
    /// - `1`：不切图（仅 overview，~9× 更少图像 token，速度最快但丢细节）
    /// - `2..9`：用户在对话页用滑条选的档位
    ///
    /// 这是 demo UI 层的"slice 数"概念，单位是 slice 数。`toCParams()` 会把它
    /// 透传到 `mb_mtmd_params.image_max_slice_nums` →
    /// `mtmd_context_params.image_max_slice_nums` →
    /// `clip_hparams.custom_image_max_slice_nums`，由 mtmd-image.cpp 的
    /// `get_slice_instructions` 读取。运行时滑条调整走
    /// `MTMDWrapper.setImageMaxSliceNums` → `mtmd_set_image_max_slice_nums`，
    /// 直接 patch hparams，下一张图编码即生效，无需重建 mtmd_context。
    public let imageMaxSliceNums: Int

    /// 单张图最大 token 数（master mtmd 的 image_max_tokens；单位 token 不是 slice）。
    ///
    /// 这是限制 vision encoder 最多产出多少 patch token 的 knob，间接控制
    /// minicpmv slicing 的 grid size：image_max_tokens 越小，mtmd 把图
    /// downscale 得越狠，模型选的 slice 数越少，prefill 期间 ViT 中间张量
    /// 的内存峰值也越小。
    ///
    /// 默认 `-1` 表示按模型默认（V4.6 上一般 9 个 slice，最大 ~600 token）。
    /// 低端机（`MBDeviceMemoryProbe.tier == .tiny`）上由 LoadModel 路径填
    /// 64 或 256 的小值，避免在多 slice 大图 prefill 时被 jetsam 杀掉。
    public let imageMaxTokens: Int

    /// MoE SSD experts 目录（含 manifest.json + 分层 expert bin）。空字符串 = 关闭。
    public let moeExpertsPath: String

    /// 每层常驻内存的 expert 槽位数。experts 开启时必须 > 0。
    public let moeSlotBank: Int

    /// 每层 decode 缓存的窗口宽度（slot 数）。0 = 不启用按层窗口（走共享 bank）。
    /// 由 app 按可用内存与 experts 每 slot 字节算出，见 MiniCPMV47Const.decodeWindow()。
    public let moeDecodeWindow: Int

    /// 跳层专家预读数（look-ahead expert prefetch）。0 = 关闭；1..16 = 预读数量。仅 experts 路径有效。
    public let moeLookaheadPrefetchDepth: Int

    /// 缓存预热档位（引擎 `LLAMA_MOE_PREWARM`）。0 = 关闭；8/16/32/48/64/96 = 每层预读这么多
    /// 个「开头最常用」的专家。表内嵌在 bridge（MBPrewarmTable.h）。改完需重载模型。
    public let moePrewarmLevel: Int

    /// 预热用哪张内嵌表（仅 `moePrewarmLevel > 0` 时生效）：
    ///   0 = 默认加权表（大小 = `moePrewarmLevel`）
    ///   1..4 = K=4 集群表（total 目标，每层 96 条）
    ///   5..8 = K=4 集群表（bottleneck 目标，每层 96 条）
    /// 集群表由 35BA3B 的 12 个 showcase case 聚类而来（见 warmup/run12/clusters/）。
    public let moePrewarmTableId: Int

    /// DSpark 草稿模型路径（GGUF）。空字符串 = 关闭投机解码。
    /// 与 `moeExpertsPath` 同一约定：作为 init 的独立参数传，由 MTMDWrapper 用 `withCString` 包住。
    public let draftModelPath: String

    /// DSpark 每轮草稿数 `n_max`。0 = 关闭投机（默认）；1..16 = 草稿块宽度。
    /// 只有 `draftModelPath` 非空且本字段 > 0 时才启用；启用后 bridge 会设
    /// `LLAMA_MOE_WINDOW_MAX_ROWS = n_max + 1` 与目标/草稿 context 的 `n_rs_seq = n_max`。
    public let specDraftNMax: Int

    /// 初始化方法
    /// - Parameters:
    ///   - modelPath: 模型路径
    ///   - mmprojPath: 多模态投影模型路径
    ///   - nPredict: 预测长度，默认 100
    ///   - nCtx: 上下文长度，默认 4096（V2.6 / V4.0 用此默认，避免高 KV 内存压力）。
    ///     V4.6 视频路径调用方应显式传入 8192：v46 在 slice=1 下每帧编码
    ///     ~64 visual tokens，64 帧 × 64 = 4096 token 恰好顶死 4096 上下文，
    ///     再叠加 system prompt + chat template wrapper 必然溢出 KV cache。
    ///     v46 模型本身 max_position_embeddings ≥ 32K，远高于 8192；
    ///     KV 多占约 270 MB，iPhone 14 Pro 及以上完全 hold 得住。
    ///   - nThreads: 线程数，默认 4
    ///   - temperature: 温度参数，**默认 0.0 = 贪心**。
    ///     0 时采样器走 `llama_sampler_init_greedy()`，结果完全可复现 ——
    ///     这是做基准测试的前提（MLPerf `mobile_inference_rules.adoc:104-117`：
    ///     采样随机性属于不允许的非确定性）。
    ///     >0 才走温度采样，此时 top_k / top_p 由 MBMtmd.mm 禁用。
    ///     ⚠️ 不再支持 `MB_TEMP` 环境变量覆盖：那个口子会让「从桌面点图标」
    ///     和「带参启动」两种方式的采样方式不同，同一次实验前后半段就不一致了。
    ///   - useGPU: 是否使用 GPU，默认 false
    ///   - mmprojUseGPU: 多模态投影是否使用 GPU，默认 false
    ///   - warmup: 是否预热，默认 true
    ///   - imageMaxSliceNums: 单张图最大切片数，默认 -1（按模型默认）。
    ///     init 时通过 mb_mtmd_params 透传给 native，运行时也可以通过
    ///     `MTMDWrapper.setImageMaxSliceNums` 动态调整。
    public init(
        modelPath: String,
        mmprojPath: String,
        nPredict: Int = 100,
        nCtx: Int = 4096,
        nThreads: Int = 4,
        temperature: Float = 0.0,
        useGPU: Bool = true,
        mmprojUseGPU: Bool = true,
        warmup: Bool = true,
        nUbatch: Int = 0,
        imageMaxSliceNums: Int = -1,
        imageMaxTokens: Int = -1,
        moeExpertsPath: String = "",
        moeSlotBank: Int = 0,
        moeDecodeWindow: Int = 0,
        moeLookaheadPrefetchDepth: Int = 0,
        moePrewarmLevel: Int = 0,
        moePrewarmTableId: Int = 0,
        draftModelPath: String = "",
        specDraftNMax: Int = 0
    ) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.nPredict = nPredict
        self.nCtx = nCtx
        self.nThreads = nThreads
        self.temperature = temperature
        self.useGPU = useGPU
        self.mmprojUseGPU = mmprojUseGPU
        self.warmup = warmup
        self.nUbatch = nUbatch
        self.imageMaxSliceNums = imageMaxSliceNums
        self.imageMaxTokens = imageMaxTokens
        self.moeExpertsPath = moeExpertsPath
        self.moeSlotBank = moeSlotBank
        self.moeDecodeWindow = moeDecodeWindow
        self.moeLookaheadPrefetchDepth = moeLookaheadPrefetchDepth
        self.moePrewarmLevel = moePrewarmLevel
        self.moePrewarmTableId = moePrewarmTableId
        self.draftModelPath = draftModelPath
        self.specDraftNMax = specDraftNMax
    }

    /// 创建默认参数
    /// - Parameters:
    ///   - modelPath: 模型路径
    ///   - mmprojPath: 多模态投影模型路径
    /// - Returns: 默认参数配置
    public static func `default`(modelPath: String, mmprojPath: String) -> MTMDParams {
        return MTMDParams(
            modelPath: modelPath,
            mmprojPath: mmprojPath
        )
    }

    /// 转换为 native bridge 的 C 结构体（不含路径，路径作为 mb_mtmd_init 的独立参数传）。
    internal func toCParams() -> mb_mtmd_params {
        var params = mb_mtmd_params_default()
        params.n_predict             = Int32(nPredict)
        params.n_ctx                 = Int32(nCtx)
        params.n_ubatch              = Int32(nUbatch)
        params.n_threads             = Int32(nThreads)
        params.temperature           = temperature
        params.use_gpu               = useGPU
        params.mmproj_use_gpu        = mmprojUseGPU
        params.warmup                = warmup
        // image_max_tokens 与 imageMaxSliceNums 单位**不同**（前者 token、后者 slice），
        // 两个 knob 都透传给 bridge：
        //   image_max_tokens     → llava-uhd dyn_size 路径（Qwen / Pixtral 等）
        //   image_max_slice_nums → llava-uhd minicpm-v 路径（实际驱动 chat 页滑条）
        // -1 表示"按模型默认"，与 native 端约定一致。
        params.image_max_tokens      = Int32(imageMaxTokens)
        params.image_max_slice_nums  = Int32(imageMaxSliceNums)
        params.moe_slot_bank         = Int32(moeSlotBank)
        params.moe_decode_window     = Int32(moeDecodeWindow)
        params.moe_lookahead_prefetch_depth        = Int32(moeLookaheadPrefetchDepth)
        params.moe_prewarm_level     = Int32(moePrewarmLevel)
        params.moe_prewarm_table_id  = Int32(moePrewarmTableId)
        params.spec_draft_n_max      = Int32(specDraftNMax)
        return params
    }
}
