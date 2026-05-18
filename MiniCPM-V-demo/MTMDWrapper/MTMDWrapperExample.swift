//
//  MTMDWrapperExample.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation
import Combine
import llama

struct ModelV2: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var filename: String
    var status: String?
}

/// 当前使用的模型
enum CurrentUsingModelTypeV2 {
    /// 未知
    case Unknown
    /// V26 多模态模型
    case V26MultiModel
    /// V4 多模态模型
    case V4MultiModel
    /// V4.6 多模态模型
    case V46MultiModel
}

/// 将要 embedding 的图片的来源
enum ImageEmbeddingTypeV2: Int {
    /// 照片或纯图片
    case Picture = 0
    /// 视频帧
    case VideoFrame = 1
    /// 实时视频帧
    case LiveVideoFrame = 2
}

/// MTMDWrapper 使用示例
@MainActor
public class MTMDWrapperExample: ObservableObject {
    
    /// MTMD 包装器实例
    internal let mtmdWrapper = MTMDWrapper()
    
    /// 取消令牌集合
    private var cancellables = Set<AnyCancellable>()
    
    /// 当前输出文本
    @Published var outputText: String = ""
    
    /// 是否正在生成
    @Published var isGenerating: Bool = false
    
    /// 错误信息
    @Published var errorMessage: String = ""
    
    /// 参数配置
    private var params: MTMDParams?
    
    /// 配置相关-begin
    
    /// 保存着所有已经下载（生效）的模型
    @Published var downloadedModels: [ModelV2] = []
    /// 未下载的模型
    @Published var undownloadedModels: [ModelV2] = []
    
    /// 如果是加载多模态模型，是否加载完成
    public var multiModelLoadingSuccess = false
    
    /// 当前生效的模型，预计会支持 V-2.6 8B 以及 V-4.0 4B 两个多模态模型
    var currentUsingModelType: CurrentUsingModelTypeV2 = .Unknown

    /// 性能日志的输出
    @Published var performanceLog = ""
    
    // 配置相关-end
    
    /// 初始化
    public init() {
        setupBindings()
    }
    
    /// 设置绑定
    private func setupBindings() {
        // 监听生成状态
        mtmdWrapper.$generationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                    case .generating:
                        self?.isGenerating = true
                        self?.errorMessage = ""
                    case .completed, .cancelled:
                        self?.isGenerating = false
                        self?.performanceLog = "Done"
                    case .failed(let error):
                        self?.isGenerating = false
                        self?.errorMessage = error.localizedDescription
                    default:
                        self?.isGenerating = false
                }
            }
            .store(in: &cancellables)
        
        // 监听完整输出
        mtmdWrapper.$fullOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] output in
                self?.outputText = output
            }
            .store(in: &cancellables)
    }
    
    /// 初始化模型
    /// - Parameters:
    ///   - modelPath: 模型路径（可选，默认使用文档目录中的模型）
    ///   - mmprojPath: 多模态投影模型路径（可选，默认使用文档目录中的模型）
    ///   - coremlPath: 已废弃。迁移到 upstream master 后 CoreML / ANE 路径暂时下线，
    ///     该参数仅为保持调用方签名而保留，会被忽略。
    ///   - nCtx: 上下文长度（可选，nil 表示用 MTMDParams 的默认值 4096）。
    ///     V4.6 视频路径建议显式传 8192：v46 视频帧 prefill 在 slice=1 下，
    ///     64 帧 × 64 visual token = 4096 token，4096 ctx 必然溢出 KV。
    ///     V2.6 / V4.0 维持 4096 以避免在低内存设备上 KV 内存压力过大。
    public func initialize(modelPath: String? = nil,
                           mmprojPath: String? = nil,
                           coremlPath: String? = nil,
                           nCtx: Int? = nil) async {
        do {
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let defaultModelPath = documentsDir.appendingPathComponent("ggml-model-Q4_0.gguf").path
            let defaultMmprojPath = documentsDir.appendingPathComponent(MiniCPMModelConst.mmprojv4_FileName).path
            
            let finalModelPath = modelPath ?? defaultModelPath
            let finalMmprojPath = mmprojPath ?? defaultMmprojPath

            // CoreML 暂时下线：保留 coremlPath 形参为了让调用方（LoadModel）签名不动，
            // 但不再传给 MTMDParams / native bridge，也不再做"看到 V4.0 mmproj 就自动 pick
            // 文档目录下 mlmodelc"的 fallback。后续重新引入 ANE 时再恢复这一段。
            if let cp = coremlPath, !cp.isEmpty {
                print("MTMDWrapperExample: 收到 coremlPath=\(cp)，但当前 master 适配版本忽略 ANE 路径")
            }

            // Seed the slice cap from the persisted user preference so
            // the new mtmd_context picks it up on init.  Live updates
            // afterwards go through `setImageMaxSliceNums` (no reload).
            let sliceCap = ImageSliceSetting.current

            // 启动时按机型挑 n_ubatch / image_max_tokens 两组档位：
            //   - n_ubatch          决定 LLM decode/prefill 的 GPU compute buffer
            //   - image_max_tokens  决定 vision encoder slice 数上限，进一步压
            //                       低端机多 slice 大图 prefill 期间的内存峰值
            // 详见 MBDeviceMemoryProbe 文件头注释。
            let tier        = MBDeviceMemoryProbe.currentTier
            let nUbatch     = tier.recommendedUbatch
            let imgMaxTok   = tier.recommendedImageMaxTokens

            // iOS Simulator 的 MTLSimDevice 在 mmproj 那种 1+ GiB 的 buffer 上
            // 直接 _xpc_api_misuse → SIGTRAP（参见 MBDeviceMemoryProbe.isSimulator
            // 注释）。在 sim 上强制全 CPU 路径走完整调用链，真机仍然 GPU。
            let useGPU       = !MBDeviceMemoryProbe.isSimulator
            let mmprojUseGPU = !MBDeviceMemoryProbe.isSimulator

            // nCtx 走"显式优先、缺省 fallback 到 MTMDParams 默认"的两段策略。
            // 调用方（LoadModel）按模型类型决定要不要抬高，避免老模型默认翻倍 KV。
            let params: MTMDParams = {
                if let n = nCtx {
                    return MTMDParams(
                        modelPath: finalModelPath,
                        mmprojPath: finalMmprojPath,
                        nCtx: n,
                        useGPU: useGPU,
                        mmprojUseGPU: mmprojUseGPU,
                        nUbatch: nUbatch,
                        imageMaxSliceNums: sliceCap,
                        imageMaxTokens: imgMaxTok
                    )
                } else {
                    return MTMDParams(
                        modelPath: finalModelPath,
                        mmprojPath: finalMmprojPath,
                        useGPU: useGPU,
                        mmprojUseGPU: mmprojUseGPU,
                        nUbatch: nUbatch,
                        imageMaxSliceNums: sliceCap,
                        imageMaxTokens: imgMaxTok
                    )
                }
            }()
            self.params = params
            try await mtmdWrapper.initialize(with: params)
            print("MTMDWrapperExample: n_ctx = \(params.nCtx), n_ubatch = \(nUbatch) (tier=\(tier.displayName)), useGPU = \(useGPU), image_max_slice_nums(UI) = \(sliceCap), image_max_tokens(bridge) = \(imgMaxTok), CoreML: 已下线")
            self.multiModelLoadingSuccess = true
        } catch {
            errorMessage = error.localizedDescription
            print("初始化失败: \(error)")
            self.multiModelLoadingSuccess = false
        }
    }
    
    /// 在后台线程中添加图片
    /// - Parameter imagePath: 图片路径
    public func addImageInBackground(_ imagePath: String) async -> Bool {
        do {
            try await mtmdWrapper.addImageInBackground(imagePath)
            return true
        } catch {
            await MainActor.run {
                errorMessage = "图片添加失败: \(error.localizedDescription)"
            }
            return false
        }
    }

    /// 与 `addImageInBackground` 相同，但把底层错误透传给调用方。
    ///
    /// 用在需要根据「成功 / 失败 / 超时」分别在 UI 上写不同 performLog 的场景
    /// （见 MBHomeViewController+ImageProcess.swift 的 prepareLoadModelAddImageToCell）。
    /// 老的 Bool 版本仍然保留，避免影响 video / live-stream 调用方。
    public func addImageInBackgroundThrowing(_ imagePath: String) async throws {
        do {
            try await mtmdWrapper.addImageInBackground(imagePath)
        } catch {
            await MainActor.run {
                errorMessage = "图片添加失败: \(error.localizedDescription)"
            }
            throw error
        }
    }

    public func addFrameInBackground(_ imagePath: String) async -> Bool {
        do {
            try await mtmdWrapper.addFrameInBackground(imagePath)
            return true
        } catch {
            await MainActor.run {
                errorMessage = "帧添加失败: \(error.localizedDescription)"
            }
            return false
        }
    }
    
    /// 在后台线程中添加文本
    /// - Parameter text: 文本内容
    public func addTextInBackground(_ text: String, role: String = "user") async -> Bool {
        do {
            try await mtmdWrapper.addTextInBackground(text, role: role)
            print("文本添加成功（后台线程）: \(text)")
            return true
        } catch {
            await MainActor.run {
                errorMessage = "文本添加失败: \(error.localizedDescription)"
            }
            return false
        }
    }
    
    /// 开始生成
    public func startGeneration() async {
        do {
            guard params != nil else {
                errorMessage = "请先初始化"
                return
            }
            
            // 添加调试信息
            print("开始生成 - 当前状态: \(mtmdWrapper.generationState)")
            try await mtmdWrapper.startGeneration()
        } catch {
            errorMessage = error.localizedDescription
            print("生成失败: \(error)")
            print("失败时的状态: \(mtmdWrapper.generationState)")
        }
    }
    
    /// 停止生成
    public func stopGeneration() {
        mtmdWrapper.stopGeneration()
        print("停止生成")
    }
    
    /// 重置
    /// 仅清 KV cache，保留 mtmd_context（轻量、毫秒级）。详见
    /// `MTMDWrapper.clearKVCacheForNewTurn` 的 doc comment。
    public func clearKVCacheForNewTurn() {
        mtmdWrapper.clearKVCacheForNewTurn()
    }

    public func reset() async {
        await mtmdWrapper.reset()
        multiModelLoadingSuccess = false
        outputText = ""
        errorMessage = ""
        print("已重置")
    }

    /// Persist + live-apply the user's chosen slice cap.  Safe to call
    /// before init: the value is stored in UserDefaults and seeded into
    /// MTMDParams on the next initialize().
    public func updateImageMaxSliceNums(_ n: Int) {
        ImageSliceSetting.update(n)
        if multiModelLoadingSuccess {
            mtmdWrapper.setImageMaxSliceNums(n)
            print("MTMDWrapperExample: live-updated image_max_slice_nums = \(n)")
        } else {
            print("MTMDWrapperExample: image_max_slice_nums = \(n) persisted; will apply on next init")
        }
    }

    /// 仅切换运行时 slice cap，不写 UserDefaults。
    ///
    /// 视频抽帧路径使用：进入视频处理前切到 1（单 overview，每帧 token 数下降一个量级），
    /// 处理完再切回用户在设置页里的原值。一旦用 `updateImageMaxSliceNums` 持久化
    /// 会把视频路径的"临时值"污染到图片路径，体验上是"用了一次视频后图片变模糊"。
    public func liveSetImageMaxSliceNums(_ n: Int) {
        guard multiModelLoadingSuccess else {
            print("MTMDWrapperExample: liveSet 调用时模型未加载，nop (n=\(n))")
            return
        }
        mtmdWrapper.setImageMaxSliceNums(n)
        print("MTMDWrapperExample: live-only image_max_slice_nums = \(n) (no persist)")
    }
}

// MARK: - 扩展 MTMDWrapper 以便在示例中访问

extension MTMDWrapper {
    /// 获取包装器实例（用于示例）
    public var wrapper: MTMDWrapper {
        return self
    }
}
