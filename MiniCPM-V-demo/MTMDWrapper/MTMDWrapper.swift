//
//  MTMDWrapper.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation
import Combine
import llama


/// MTMD 多模态推理包装器
@MainActor
public class MTMDWrapper: ObservableObject {
    
    // MARK: - Published Properties
    
    /// 当前输出 Token
    @Published public private(set) var currentToken: MTMDToken = .empty
    
    /// 完整的输出内容
    @Published public private(set) var fullOutput: String = ""
    
    /// 生成状态
    @Published public private(set) var generationState: MTMDGenerationState = .idle
    
    /// 初始化状态
    @Published public private(set) var initializationState: MTMDInitializationState = .notInitialized
    
    /// 是否有内容可以生成
    @Published public private(set) var hasContent: Bool = false
    
    /// 是否为纯文本模型（影响 <think> 注入行为）
    public var isTextOnlyModel: Bool = false

    /// MiniCPM5 / V-4.6 thinking toggle. Default off. Applied on the next user turn.
    public var enableThinking: Bool = false

    /// 自动化基准用：>0 时生成到该 token 数就停，不等 EOG。
    /// 固定步数是让不同 depth / 不同设备的 decode t/s 可比的前提 —— 否则
    /// 生成长度随模型输出变化，t/s 会混入"生成了多长"这个无关变量。
    public var decodeTokenLimit: Int = 0

    /// decode 循环每步的让出时长（纳秒），由 `-genSleepMs N` 覆盖，默认 10 ms。
    ///
    /// 这个让出原本是「避免过度占用 CPU」，但实测它是 decode 速度的一大变量：
    /// 每步 GPU 计算只有 ~30 ms，中间空出 10 ms 会让 GPU 的 DVFS 掉档，
    /// 下一步的计算因此变慢（同一条 case 在「界面持续渲染」的对话路径里快 15~17%）。
    /// 传 0 即可让 GPU 队列保持饱和，用于对照实验。
    ///
    /// 默认值按路径区分：**bench 用 3 ms，日常对话保持 10 ms**。
    /// 依据是实测（月相 case，203 token）：
    ///   让出 10 ms → 17.5 t/s；3 ms → 22.4 t/s；0 ms → 20.6 t/s（采样时反而要等 GPU）。
    /// 对话路径之所以"看起来快"，是因为那 10 ms 被界面渲染填满了、GPU 不掉档；
    /// bench 没有渲染，10 ms 就等于把 GPU 队列抽空。
    /// 对话侧行为本次不动（产品决策另说），只用 `-genSleepMs` 可覆盖调试。
    private static let genSleepNanos: UInt64 = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-genSleepMs"), i + 1 < args.count, let v = Int(args[i + 1]) {
            return UInt64(max(0, min(v, 1000))) * 1_000_000
        }
        return args.contains("-bench") ? 3_000_000 : 10_000_000
    }()

    /// 目标 TPOT（毫秒/token），0 = 不配速。由 `-benchTpotMs N` 设置。
    ///
    /// 用途：让**不读盘**的 B 档按 A 档的速度跑，否则两档 GPU 占空比差一倍多，
    /// 功率做差衡量的是吞吐差异而不是搬运代价（iPhone 上实测 B 快 2.45 倍）。
    private static let benchTpotNanos: UInt64 = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-benchTpotMs"), i + 1 < args.count, let v = Int(args[i + 1]) {
            return UInt64(max(0, min(v, 60_000))) * 1_000_000
        }
        return 0
    }()

    /// 本步让出：至少 `genSleepNanos`；若设了 TPOT 且本步太快，补到目标间隔。
    private static func pace(stepStart: Date) async {
        var waitNanos = genSleepNanos
        if benchTpotNanos > 0 {
            let elapsedNanos = Date().timeIntervalSince(stepStart) * 1_000_000_000.0
            let remain = Double(benchTpotNanos) - elapsedNanos
            if remain > 0 {
                waitNanos = max(waitNanos, UInt64(remain))
            }
        }
        if waitNanos > 0 {
            try? await Task.sleep(nanoseconds: waitNanos)
        }
    }

    /// `true` 时 `decodeTokenLimit` 退化为**上限**：撞 EOG 就停，只有跑到上限才强制截断。
    /// `false`（历史行为）时才忽略 EOG、强行生成到固定步数。
    ///
    /// 功耗测量应该用 `true`：固定步数会把输出长度硬拽到上限，
    /// 让 A 档和日常对话的 token 序列不再是同一条，横向比就没意义了。
    public var stopAtEOG: Bool = false

    /// 26=V2.6, 40=V4.0, 46/460/461=V4.6, 47=V4.7 MoE SSD, 5=MiniCPM5
    public private(set) var modelVersion: Int = 0

    private var supportsThinkingPrefix: Bool {
        isTextOnlyModel || modelVersion == 46 || modelVersion == 460 || modelVersion == 461
    }
    
    // MARK: - Private Properties
    
    /// MTMD 上下文指针
    private var context: OpaquePointer?
    
    /// 生成参数
    /// 初始化参数。
    ///
    /// 放宽为 internal + private(set)：批量基准测试需要读回实际生效的采样温度，
    /// 用来在跑批前拦住「温度非 0 → 结果不可复现」这种情况
    /// （MLPerf `mobile_inference_rules.adoc:104-117` 只允许浮点序 / 输入随机遍历 /
    /// 舍入三种非确定性，采样随机不在其中）。只放开读，写仍在类型内部。
    private(set) var params: MTMDParams?
    
    /// 生成任务
    private var generationTask: Task<Void, Never>?

    /// 最近一轮 native prefill / decode 计数（生成结束时 snapshot）
    public private(set) var lastPerf = mb_mtmd_perf(
        prefill_tokens: 0, decode_tokens: 0, prefill_ms: 0, decode_ms: 0, prep_ms: 0,
        moe_k_prefill: 0, moe_k_decode: 0, image_tokens: 0, image_encode_ms: 0
    )

    /// 生成过程中实时刷新的 decode 速度文案（「实时速度」开关打开时才更新）。
    ///
    /// 与 `lastPerf` 的分工：这个在流式期间每 ~50 ms 刷新一次，读的是
    /// `mb_mtmd_perf_peek`（只取计数，不结束回合、不写日志、不落 park）。
    public private(set) var liveSpeedText: String = ""

    /// 实时速度的采样点：存**累计值**（tokens / ms），用最近若干 token 的增量算「当前速度」。
    ///
    /// 不能直接拿整回合累计值相除 —— 那会把冷启动热身永远算进分母。实测第 1 步的读盘量
    /// 是稳态的 1.8 倍（c=25）到 6.7 倍（c=128），要 20~60 步才落稳；累计平均会系统性低估，
    /// 且前 20 步抖得最厉害。
    private struct LivePerfSample {
        let tokens: Int32
        let ms: Double
    }
    private var livePerfSamples: [LivePerfSample] = []
    /// 滑动窗口长度：**按 token 个数**，不是按秒数。
    ///
    /// 用秒数会让平滑度随速率变化 —— 慢档 3.4 t/s 时 1 秒窗口里只有 3~4 个 token，
    /// 边界抖动会让 Δtokens 在 2~5 之间跳，显示就在 2.0~5.0 t/s 来回摆（±40%）。
    /// 固定 token 数后噪声恒定在 ±1/N，窗口时长自动适配（N=12：慢档约 3.5 s，快档约 1.2 s）。
    private let livePerfTokenWindow = 12
    /// 最近一个窗口算出的 decode 速度（t/s）。只供「实时速度」显示用。
    private var liveDecodeRate: Double?
    
    /// 生成队列
    private let generationQueue = DispatchQueue(label: "com.mtmd.generation", qos: .userInitiated)
    
    /// 线程锁
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    public init() {
        print("MTMDWrapper: 初始化")
    }
    
    deinit {
        // 在 deinit 中同步清理资源
        generationTask?.cancel()
        generationTask = nil
        
        // 清理资源
        if let ctx = context {
            mb_mtmd_free(ctx)
            context = nil
        }
        
        print("MTMDWrapper: 析构函数清理完成")
    }
    
    // MARK: - Public Methods
    
    /// 初始化 MTMD 上下文
    /// - Parameter params: 初始化参数
    public func initialize(with params: MTMDParams) async throws {
        guard initializationState != .initializing else {
            throw MTMDError.alreadyInitializing
        }
        
        guard initializationState != .initialized else {
            throw MTMDError.alreadyInitialized
        }
        
        updateInitializationState(.initializing)
        
        // 在后台线程执行初始化
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var cParams = params.toCParams()
                // 路径在新 bridge 里作为 mb_mtmd_init 的独立参数传，
                // 避免把 const char * 字段塞进结构体后 Swift 闭包外指针失效。
                let draftPath = params.draftModelPath
                let ctx: OpaquePointer? = params.modelPath.withCString { modelCStr in
                    params.mmprojPath.withCString { mmprojCStr in
                        draftPath.withCString { draftCStr in
                            let draftPtr: UnsafePointer<CChar>? = draftPath.isEmpty ? nil : draftCStr
                            if params.moeExpertsPath.isEmpty {
                                return mb_mtmd_init(modelCStr, mmprojCStr, nil, draftPtr, &cParams)
                            }
                            return params.moeExpertsPath.withCString { expertsCStr in
                                mb_mtmd_init(modelCStr, mmprojCStr, expertsCStr, draftPtr, &cParams)
                            }
                        }
                    }
                }

                if ctx == nil {
                    let raw = mb_mtmd_last_init_error()
                    let detail = (raw != nil) ? String(cString: raw!) : ""
                    let msg = detail.isEmpty ? "无法创建 MTMD 上下文" : detail
                    continuation.resume(throwing: MTMDError.initializationFailed(msg))
                    return
                }
                
                // 回到主线程更新状态
                Task { @MainActor in
                    self.context = ctx
                    self.params = params
                    self.initializationState = .initialized
                    mb_mtmd_set_enable_thinking(ctx, self.enableThinking)
                    print("MTMDWrapper: 初始化成功")
                    continuation.resume()
                }
            }
        }
    }

    /// 初始化纯文本模型（无 mmproj / 视觉模块）
    public func initializeTextOnly(with params: MTMDParams) async throws {
        guard initializationState != .initializing else {
            throw MTMDError.alreadyInitializing
        }
        guard initializationState != .initialized else {
            throw MTMDError.alreadyInitialized
        }

        updateInitializationState(.initializing)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var cParams = params.toCParams()
                let expertsPath = params.moeExpertsPath
                let draftPath   = params.draftModelPath
                let ctx = params.modelPath.withCString { modelCStr in
                    // 空 experts → 传 nullptr（纯 dense 文本模型）。
                    // 非空 → 走 MoE SSD 流式，35B-A3B 全量专家在 8GB 手机上放不下。
                    // 空 draft → 传 nullptr（投机解码关闭）。
                    expertsPath.withCString { expertsCStr in
                        draftPath.withCString { draftCStr in
                            mb_mtmd_init_text_only(modelCStr,
                                                   expertsPath.isEmpty ? nil : expertsCStr,
                                                   draftPath.isEmpty ? nil : draftCStr,
                                                   &cParams)
                        }
                    }
                }

                if ctx == nil {
                    let raw = mb_mtmd_last_init_error()
                    let detail = (raw != nil) ? String(cString: raw!) : ""
                    let msg = detail.isEmpty ? "无法创建纯文本模型上下文" : detail
                    continuation.resume(throwing: MTMDError.initializationFailed(msg))
                    return
                }

                Task { @MainActor in
                    self.context = ctx
                    self.params = params
                    self.isTextOnlyModel = true
                    self.initializationState = .initialized
                    mb_mtmd_set_enable_thinking(ctx, self.enableThinking)
                    print("MTMDWrapper: 纯文本模型初始化成功")
                    continuation.resume()
                }
            }
        }
    }

    /// addImageInBackground / addFrameInBackground 默认超时（秒）。
    ///
    /// MiniCPM-V 4.6 + 9 切片 + 首次 ANE 编译，最坏路径在老设备上也通常 < 60s。
    /// 给 180s 是为了"宁可慢但保住功能"，超过这个时间几乎一定是 ANE driver
    /// 卡住或者磁盘 IO 卡住，应当上报失败让 UI 兜底。
    public static let defaultPrefillTimeoutSeconds: TimeInterval = 180

    /// 在后台线程中添加图片（非 @MainActor 版本）
    /// - Parameter timeoutSeconds: 等待 prefill_image 的上限。超时抛 MTMDError.timeout，
    ///   让上层走兜底分支而不是永远卡住。注意 C++ 同步 API 不可中断，超时后底层仍会跑完。
    public func addImageInBackground(_ imagePath: String,
                                     timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds) async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }

        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }

        try await runWithWatchdog(
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: "addImageInBackground timed out after \(Int(timeoutSeconds))s (image=\(imagePath))"
        ) { resumeOnce in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = imagePath.withCString { mb_mtmd_prefill_image(ctx, $0) }

                if result != 0 {
                    let errorMessage = mb_mtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    print("MTMDWrapper: addImageInBackground failed, imagePath=\(imagePath), error=\(error)")
                    resumeOnce(.failure(MTMDError.imageLoadFailed(error)))
                } else {
                    Task { @MainActor in
                        self.hasContent = true
                        resumeOnce(.success(()))
                    }
                }
            }
        }
    }

    /// 选图编码后的隐藏步骤：重建自适应 ubatch + 预热（纯优化，不抛错）。
    /// 别与 addImageInBackground 合回去 —— 上层「预处理耗时」包着后者，预热会被计入。
    public func prewarmAfterImageInBackground(
        timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds
    ) async {
        guard initializationState == .initialized, let ctx = context else { return }

        do {
            try await runWithWatchdog(
                timeoutSeconds: timeoutSeconds,
                timeoutMessage: "prewarmAfterImageInBackground timed out after \(Int(timeoutSeconds))s"
            ) { resumeOnce in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = mb_mtmd_prewarm_after_image(ctx)
                    resumeOnce(.success(()))
                }
            }
        } catch {
            print("MTMDWrapper: prewarmAfterImageInBackground failed: \(error)")
        }
    }

    public func addFrameInBackground(_ imagePath: String,
                                     timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds) async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }

        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }

        try await runWithWatchdog(
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: "addFrameInBackground timed out after \(Int(timeoutSeconds))s (frame=\(imagePath))"
        ) { resumeOnce in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = imagePath.withCString { mb_mtmd_prefill_frame(ctx, $0) }

                if result != 0 {
                    let errorMessage = mb_mtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    print("MTMDWrapper: addFrameInBackground failed, imagePath=\(imagePath), error=\(error)")
                    resumeOnce(.failure(MTMDError.imageLoadFailed(error)))
                } else {
                    Task { @MainActor in
                        self.hasContent = true
                        resumeOnce(.success(()))
                    }
                }
            }
        }
    }
    
    /// 在后台线程中添加文本（非 @MainActor 版本）
    /// - Parameters:
    ///   - text: 文本内容
    ///   - role: 角色（user/assistant）
    public func addTextInBackground(_ text: String, role: String = "user") async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }
        
        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }
        
        // 在后台线程执行 C 函数调用
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = text.withCString { textCStr in
                    role.withCString { roleCStr in
                        mb_mtmd_prefill_text(ctx, textCStr, roleCStr)
                    }
                }

                if result != 0 {
                    let errorMessage = mb_mtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    continuation.resume(throwing: MTMDError.textAddFailed(error))
                } else {
                    // 回到主线程更新状态
                    Task { @MainActor in
                        self.hasContent = true
                        print("MTMDWrapper: 文本添加成功（后台线程）: \(text)")
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    /// 开始生成
    public func startGeneration() async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }
        
        guard hasContent else {
            throw MTMDError.noContentToGenerate
        }
        
        // 允许在空闲或已完成状态下重新开始生成
        guard generationState == .idle || generationState == .completed else {
            throw MTMDError.generationInProgress
        }
        
        updateGenerationState(.generating)
        
        // 取消之前的生成任务
        generationTask?.cancel()
        
        // 创建新的生成任务
        generationTask = Task {
            await performGeneration()
        }
    }
    
    /// 停止生成
    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        // 只有在当前状态不是 completed 时才重置为 idle
        if generationState != .completed {
            updateGenerationState(.completed)
        }
        print("MTMDWrapper: 生成已停止")
    }

    /// 聊天工具条是否显示 "prefill / decode t/s"。
    ///
    /// 改为设置页可切换（原为编译期常量）：调试要看到、录制 case 又不想带上 t/s，
    /// 而改常量每次都要重编。关掉只是不显示；native 那行 `[MBMtmd] perf app:` 不受影响。
    public static var showPerfSpeedInToolbar: Bool {
        MiniCPMV47Const.showPerfSpeedEnabled()
    }

    /// 对话框工具条用的 "prefill x.x t/s  decode y.y t/s  Kp/Kd"。
    /// `showPerfSpeedInToolbar` 为 false 时返回空串，调用方据此隐藏。
    public func lastPerfDisplayString() -> String {
        guard MTMDWrapper.showPerfSpeedInToolbar else { return "" }
        func tokPerSec(tokens: Int32, ms: Double) -> Double {
            guard tokens > 0, ms > 0 else { return 0 }
            return Double(tokens) / (ms / 1000.0)
        }
        let p = tokPerSec(tokens: lastPerf.prefill_tokens, ms: lastPerf.prefill_ms)
        let d = tokPerSec(tokens: lastPerf.decode_tokens, ms: lastPerf.decode_ms)
        return String(format: "prefill %.1f t/s  decode %.1f t/s", p, d)
    }

    /// 流式过程中的实时 decode 速度。开关关闭时返回空串，调用方据此隐藏。
    ///
    /// 只报 decode：prefill 在这时候早就结束了，混在一起反而看不出生成速度。
    public func livePerfDisplayString() -> String {
        liveSpeedText
    }

    /// 记一个 decode 采样点，用最近 N 个 token 的增量更新实时速度。
    /// 只在 token 数增加时记录（否则同一计数被重复记录，窗口边界乱跳）。
    /// 只服务「实时速度」开关；「显示 P/D 速度」走整回合平均，两者互不影响。
    private func recordDecodeSample(_ perf: mb_mtmd_perf) {
        guard perf.decode_tokens > 0 else { return }
        if let last = livePerfSamples.last, last.tokens == perf.decode_tokens { return }
        livePerfSamples.append(LivePerfSample(tokens: perf.decode_tokens, ms: perf.decode_ms))
        // 量 N 个 token 的间隔需要 N+1 个点。
        while livePerfSamples.count > livePerfTokenWindow + 1 {
            livePerfSamples.removeFirst()
        }
        guard let oldest = livePerfSamples.first, livePerfSamples.count > 1 else { return }
        let dTokens = Double(perf.decode_tokens - oldest.tokens)
        let dMs = perf.decode_ms - oldest.ms
        guard dTokens > 0, dMs > 0 else { return }
        liveDecodeRate = dTokens / (dMs / 1000.0)
    }
    
    /// 运行时调整单图最大切片数（无需 reload mmproj）：clip 每张图都会重读
    /// hparams.custom_image_max_slice_nums。n: 1=不切图，9=模型上限，-1=模型默认。
    public func setImageMaxSliceNums(_ n: Int) {
        guard let ctx = context else {
            // 还没 init 完，下一次 initialize() 会通过 MTMDParams 把值带进去。
            print("MTMDWrapper: setImageMaxSliceNums 调用时上下文未就绪，nop")
            return
        }
        mb_mtmd_set_image_max_slice_nums(ctx, Int32(n))
        print("MTMDWrapper: setImageMaxSliceNums(\(n)) 已调用，下一张图编码时生效")
    }

    /// Set the model version so the C bridge can pick the correct prompt template.
    /// - Parameter version: 26=V2.6, 40=V4.0, 46=V4.6, 5=MiniCPM5
    public func setModelVersion(_ version: Int) {
        modelVersion = version
        guard let ctx = context else { return }
        mb_mtmd_set_model_version(ctx, Int32(version))
    }

    /// MiniCPM5 / V-4.6 thinking toggle. Stored locally so it survives a later init,
    /// and pushed to the C bridge when a context exists.
    public func setEnableThinking(_ enable: Bool) {
        enableThinking = enable
        guard let ctx = context else { return }
        mb_mtmd_set_enable_thinking(ctx, enable)
    }

    public func setMoeLookaheadPrefetchDepth(_ depth: Int) {
        guard let ctx = context else { return }
        let applied = mb_mtmd_set_moe_lookahead_prefetch_depth(ctx, Int32(depth))
        print("MTMDWrapper: setMoeLookaheadPrefetchDepth(\(depth)) -> \(applied)")
    }

    /// 重置上下文
    public func reset() async {
        stopGeneration()
        
        // 清理资源
        if let ctx = context {
            mb_mtmd_free(ctx)
            context = nil
        }
        
        // 重置状态
        initializationState = .notInitialized
        generationState = .idle
        currentToken = .empty
        fullOutput = ""
        livePerfSamples.removeAll(keepingCapacity: true)
        liveDecodeRate = nil
        liveSpeedText = ""
        hasContent = false
        isTextOnlyModel = false
        modelVersion = 0
        params = nil
        
        print("MTMDWrapper: 上下文已重置")
    }

    /// 仅清 KV cache + n_past=0，保留 context / sampler 不重建。
    /// 用途：开一段独立 prefill turn（视频抽帧、场景切换），对齐 Python 端每次
    /// chat() 都从干净 KV 开始。避免长对话 + 抽帧顶穿 n_ctx —— 混合 SSM 模型
    /// 单 chunk 失败后无法部分截断，整 ctx 就废了。O(1)，毫秒级。
    public func clearKVCacheForNewTurn() {
        guard let ctx = context else { return }
        let ok = mb_mtmd_clean_kv_cache(ctx)
        print("MTMDWrapper: clearKVCacheForNewTurn -> \(ok)")
        // 同步 Swift 侧的"有内容"标志，避免 startGeneration 因为旧标志而尝试用空 KV 跑
        hasContent = false
    }
    
    /// 清理资源
    public func cleanup() async {
        await reset()
    }
    
    // MARK: - Private Methods
    
    /// 执行生成。节流：本地 accumulated 累加，只在「首 token / 距上次 flush ≥
    /// flushIntervalMs / 结束」时同步到 @Published fullOutput。
    /// 每 token 直写会把主线程打到 ~400 次/秒（属性 hop + sink 链 + cell 重绘），
    /// 现象是打字卡顿、第三方输入法 candidate 超时。现在降到 ≤20 次/秒。
    private func performGeneration() async {
        guard let ctx = context else {
            updateGenerationState(.failed(.contextNotInitialized))
            return
        }

        // MiniCPM5 / V-4.6: <think>\n is injected into the prompt as a
        // special token, so the model won't generate it itself. Pre-seed
        // fullOutput so the UI can parse <think>...</think> blocks.
        var accumulated: String = (supportsThinkingPrefix && enableThinking) ? "<think>\n" : ""
        fullOutput = accumulated

        // 50ms = 20 fps 节流。再短主线程会被打扰太多次（每帧 sink → markdown
        // 高度计算 → scroll），再长用户能看出"一卡一卡"出字（不流畅）。
        let flushIntervalMs: TimeInterval = 0.050
        // 用 distantPast 保证循环第一个 token 一定立即 flush，让 UI 立刻有反应。
        var lastFlush: Date = .distantPast
        // 新回合：清掉上一回合的采样点。否则第一次求差会跨回合 —— 累计值已归零，
        // 拿旧回合的大值当被减数会得到负数，窗口内又只剩一个点可用。
        livePerfSamples.removeAll(keepingCapacity: true)
        liveDecodeRate = nil
        liveSpeedText = ""
        // 固定步数模式（基准）：只数真正生成的 token，不含预置的 <think> 前缀。
        var nDecoded = 0

        // 生成循环
        while !Task.isCancelled {
            // 本步起点：配速（`-benchTpotMs`）以「相邻 token 的起始间隔」为准
            let stepStart = Date()

            // 在后台线程执行 C 函数调用
            let cToken = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let token = mb_mtmd_loop(ctx)
                    continuation.resume(returning: token)
                }
            }

            var tokenString = cToken.token != nil ? String(cString: cToken.token!) : ""

            // 在主线程更新状态
            currentToken = MTMDToken(content: tokenString, isEnd: cToken.is_end)
            if accumulated.isEmpty && tokenString == "\n" {
                tokenString = ""
            }
            accumulated += tokenString

            // 释放 native bridge 在 mb_mtmd_loop 里 malloc 出来的 token 字符串。
            // 这个 free 是必须的；旧 mtmd-ios 时代被注释掉是因为当时漏 free，
            // 长会话下会持续涨内存。新 bridge 必须显式归还。
            if let tokenPtr = cToken.token {
                mb_mtmd_string_free(tokenPtr)
            }

            // 节流：把高频 token 累加合并成 ≤20 fps 的 fullOutput 广播。
            let now = Date()
            let shouldFlush = cToken.is_end
                || now.timeIntervalSince(lastFlush) >= flushIntervalMs
            if shouldFlush {
                // 实时速度：读计数但不结束回合。此刻后台 mb_mtmd_loop 已返回、
                // 下一次还没开始，所以读计数没有并发写。
                if MiniCPMV47Const.liveTpsEnabled() {
                    recordDecodeSample(mb_mtmd_perf_peek(ctx))
                    liveSpeedText = liveDecodeRate.map { String(format: L.Home.liveDecodeSpeed.loc, $0) } ?? ""
                } else {
                    liveSpeedText = ""
                }
                fullOutput = accumulated
                lastFlush = now
            }

            // 检查是否生成完成
            if cToken.is_end {
                // ── 基准固定步数模式：**忽略 EOG**，继续解码到上限 ──
                //
                // 为什么必须忽略：`decodeTokenLimit` 原本只是「最多生成多少」，撞 EOG 就提前停。
                // 实测 12 条 case × 2 轮里只有 12/24 能跑满 256，其余在 53~222 就停了。
                // 输出长度不同 → decode 步数不同 → 单条 wall 与能耗不可跨 case 比较，
                // 而功耗拆解恰恰要横向比。MLPerf 性能模式同样要求「固定输出长度、忽略 EOG」。
                //
                // 安全性：桥接层在返回 is_end 之前**已经把 EOG 喂进 KV 并计入 decode_tokens**
                // （MBMtmd.mm:3084-3098），所以继续调 mb_mtmd_loop 时 n_past 连续，
                // 不会出现位置空洞。
                if decodeTokenLimit > 0 && !stopAtEOG {
                    // 但要区分「EOG」与「解码失败」—— 后者同样返回 is_end。
                    // 出错时 last_error 非空，必须停，否则会在坏状态上空转。
                    let errPtr = mb_mtmd_get_last_error(ctx)
                    let errMsg = errPtr != nil ? String(cString: errPtr!) : ""
                    if !errMsg.isEmpty {
                        lastPerf = mb_mtmd_perf_snapshot(ctx)
                        updateGenerationState(.failed(.generationFailed(errMsg)))
                        print("MTMDWrapper: 固定步数模式下解码失败，中止：\(errMsg)")
                        generationTask = nil
                        return
                    }

                    nDecoded += 1
                    if nDecoded >= decodeTokenLimit {
                        lastPerf = mb_mtmd_perf_snapshot(ctx)
                        mb_mtmd_log_text("OUTPUT(fixed-length)", accumulated)
                        updateGenerationState(.completed)
                        print("MTMDWrapper: 达到固定步数 \(decodeTokenLimit)（期间已忽略 EOG）")
                        generationTask = nil
                        return
                    }
                    // 与正常路径保持同样的让出节奏（含 TPOT 配速），
                    // 否则基准路径的 GPU 占空比会与正常路径不同。
                    await Self.pace(stepStart: stepStart)
                    continue
                }

                lastPerf = mb_mtmd_perf_snapshot(ctx)
                // 自然结束模式同样要区分「真 EOG」与「解码失败」——
                // 固定步数分支（上面）早就做了，这里漏了：桥接层一旦带错误返回
                // is_end，会被当成正常结束，表现就是「只生成 1 个 token 就停」且无报错。
                let errPtr = mb_mtmd_get_last_error(ctx)
                let errMsg = errPtr != nil ? String(cString: errPtr!) : ""
                if !errMsg.isEmpty {
                    updateGenerationState(.failed(.generationFailed(errMsg)))
                    print("MTMDWrapper: 自然结束模式下解码失败，中止：\(errMsg)")
                    generationTask = nil
                    return
                }
                if nDecoded <= 1 {
                    // 实测 `-benchTokens 0/-1` 下第 1 个 token 就收到 is_end，
                    // 而同样 prompt 在固定步数模式（忽略 is_end 继续跑）能正常吐满
                    // 203 个 token —— 说明这个 is_end 是假的。先把现场打全便于定位，
                    // 不在这里硬续跑（那会污染自然停止的语义）。
                    print("MTMDWrapper: ⚠️ 自然结束：第 \(nDecoded) 个 token 就收到 is_end"
                          + "（已产出 \(accumulated.utf8.count) 字节，last_error 为空），疑似假 EOG")
                }
                mb_mtmd_log_text("OUTPUT(full)", accumulated)
                updateGenerationState(.completed)
                print("MTMDWrapper: 生成完成: \(fullOutput)")
                // 清理任务引用但不重置状态，让状态保持为 completed
                // 注意：不在这里清 KV cache，否则多轮上下文会丢。
                // KV 的清理统一交给显式 reset()（切换模型 / 新对话入口）
                generationTask = nil
                return
            }

            // 固定步数模式：够了就停，不等 EOG。基准要的是固定解码步数，
            // 否则生成长度随模型输出变化，t/s 会混入无关变量，跨 depth/设备不可比。
            nDecoded += 1
            if decodeTokenLimit > 0 && nDecoded >= decodeTokenLimit {
                lastPerf = mb_mtmd_perf_snapshot(ctx)
                // 与「撞 EOG 自然结束」区分开：这里是**被上限截断**。
                mb_mtmd_log_text("OUTPUT(max-tokens)", accumulated)
                updateGenerationState(.completed)
                print("MTMDWrapper: 达到固定步数上限 \(decodeTokenLimit)，停止生成")
                generationTask = nil
                return
            }

            // 让出 + 配速（`-genSleepMs` / `-benchTpotMs`）。
            await Self.pace(stepStart: stepStart)
        }

        // 用户点了停止：仍留下这一轮已经跑过的 prefill / decode 数据。
        lastPerf = mb_mtmd_perf_snapshot(ctx)
        mb_mtmd_log_text("OUTPUT(interrupted)", accumulated)
    }
    
    /// 给同步阻塞型 C 调用包一层 watchdog 超时。
    /// body 必须在后台线程启动 C 调用并用 resumeOnce 上报；watchdog 先到则 body
    /// 的 resumeOnce 变 no-op，但 C 调用仍会跑完（不可中断）。下一次进入会先
    /// clean_kv_cache，被孤儿化的那次推理不留污染。
    private func runWithWatchdog(
        timeoutSeconds: TimeInterval,
        timeoutMessage: String,
        body: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        // 把 idempotent 的 resume 状态寄存到一个引用类型上（class wrapper），
        // 避免在 @escaping 闭包之间共享 var 导致的 Sendable 警告。
        final class ResumeState {
            let lock = NSLock()
            var didResume = false
        }
        let state = ResumeState()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                state.lock.lock()
                if state.didResume {
                    state.lock.unlock()
                    return
                }
                state.didResume = true
                state.lock.unlock()

                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            body(resumeOnce)

            // watchdog：用 utility QoS 的全局队列，避免抢占 userInitiated。
            // 时机点过了就触发 timeout，但如果 worker 已经先 resume，
            // resumeOnce 会自动 no-op。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                resumeOnce(.failure(MTMDError.timeout(timeoutMessage)))
            }
        }
    }

    /// 更新初始化状态
    private func updateInitializationState(_ state: MTMDInitializationState) {
        initializationState = state
    }
    
    /// 更新生成状态
    private func updateGenerationState(_ state: MTMDGenerationState) {
        generationState = state
    }
}

