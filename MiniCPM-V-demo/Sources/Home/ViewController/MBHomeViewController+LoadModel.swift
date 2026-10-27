//
//  MBHomeViewController+LoadModel.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/7/12.
//

import Foundation
import UIKit

extension MBHomeViewController {
    
    /// 尝试重新加载多模态模型
    func checkMultiModelLoadStatusAndLoadIt() {
    
        // OcrModel and Voxcpm2Model are loaded by OcrEngine / TtsEngine respectively,
        // not by the MTMD wrapper.  Bail out unconditionally to avoid loading the
        // OCR GGUF as a chat model in parallel with the OCR engine.
        let selected = UserDefaults.standard.string(forKey: "current_selected_model") ?? ""
        if selected == "OcrModel" || selected == "Voxcpm2Model" {
            return
        }

        if self.mtmdWrapperExample?.multiModelLoadingSuccess == true {
            return
        }
        
        // 显示加载 HUD。
        // 第二行是最朴素的多行 UILabel 文案：避免 attributedText / Timer 心跳那种花哨方案。
        // 在多次切换模型反复 reset + init 的场景里，跨 main actor 写 attributedText / 长生命
        // 周期 Timer 持有 hud 会跟 vc dealloc 路径竞争，触发
        // `Cannot form weak reference to MBHomeViewController` 崩溃 + 白屏。
        // 静态多行文案在 vc 完全 attach 之后再被 alpha 动画显示出来，没有任何额外引用链，最稳。
        let hud = MBHUD.showAdded(to: self.view, animated: true)
        hud.mode = .indeterminate
        hud.label.text = L.Home.hudLoadingModel.loc
        
        Task.detached(priority: .userInitiated) {

            var modelURL: URL?
            var mmprojURL: URL?
            var selectedModelType: CurrentUsingModelTypeV2 = .Unknown
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            MBModelArtifactStore.migrateLegacySharedModel(in: documentsDirectory)
            MBModelArtifactStore.purgeStaleV46MMProj(in: documentsDirectory)

            // 基准/诊断：把关键状态打出来。之前一次真机运行停在 "MTMDWrapper: 初始化"
            // 却没有任何线索，只能靠翻源码推断——有这行不用再猜。
            let benchArgs = ProcessInfo.processInfo.arguments.dropFirst().filter { $0.hasPrefix("-moe") }
            if !benchArgs.isEmpty {
                // 关键：`devicectl --console` 下 stdout 是管道 → C stdio 块缓冲（4KB），
                // 进程被超时杀掉时缓冲全丢。基准场景改成无缓冲，所有 print 即时可见。
                setvbuf(stdout, nil, _IONBF, 0)
                self.benchLog("[MOEBENCH] args=\(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))")
                let v47dir = documentsDirectory.appendingPathComponent(MiniCPMV47Const.documentsDirName)
                for name in [MiniCPMV47Const.modelFileName, MiniCPMV47Const.mmprojFileName, MiniCPMV47Const.expertsDirName] {
                    let p = v47dir.appendingPathComponent(name)
                    self.benchLog("[MOEBENCH] exists(\(name))=\(FileManager.default.fileExists(atPath: p.path))")
                }
            }
            
            
            // 判断用户在设置页选中的模型
            var lastSelectedModelString = UserDefaults.standard.value(forKey: "current_selected_model") as? String ?? ""
            if lastSelectedModelString.isEmpty {
                lastSelectedModelString = MiniCPMV47Const.userDefaultsKey
            }
            if lastSelectedModelString == MiniCPMV47Const.userDefaultsKey {
                // 纯文本基准（-moeTextOnly）不要求 mmproj：那条路只用 model + experts。
                let benchTextOnly = ProcessInfo.processInfo.arguments.contains("-moeTextOnly")
                if let artifacts = MiniCPMV47Const.resolveArtifacts(in: documentsDirectory,
                                                                   requireMMProj: !benchTextOnly) {
                    modelURL = artifacts.modelURL
                    mmprojURL = artifacts.mmprojURL
                    selectedModelType = .V47MoE
                }
            } else if lastSelectedModelString == MiniCPMV47_1BConst.userDefaultsKey {
                // MiniCPM-V 4.7 1B（dense，无 experts）：只需要 model + mmproj。
                if let artifacts = MiniCPMV47_1BConst.resolveArtifacts(in: documentsDirectory) {
                    modelURL = artifacts.modelURL
                    mmprojURL = artifacts.mmprojURL
                    selectedModelType = .V47_1B
                }
            } else if lastSelectedModelString == "V26MultiModel" {
                // V-2.6 8B 多模态模型
                modelURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.modelQ4_K_MFileName)
                mmprojURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.mmprojFileName)
                selectedModelType = .V26MultiModel
            } else if lastSelectedModelString == "V4MultiModel" {
                // V-4.0 4B 多模态模型
                modelURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.modelv4_Q4_K_M_FileName)
                mmprojURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.mmprojv4_FileName)
                selectedModelType = .V4MultiModel
            } else if lastSelectedModelString == "V46MultiModel" {
                // V-4.6 多模态模型
                modelURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.modelv46_FileName)
                mmprojURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.mmprojv46_FileName)
                selectedModelType = .V46MultiModel
            } else if lastSelectedModelString == "V5TextModel" {
                // MiniCPM 5 纯文本模型（无 mmproj）
                modelURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.modelv5_FileName)
                selectedModelType = .V5TextModel
            } else if lastSelectedModelString == "V526TextModel" {
                // MiniCPM5-2B 纯文本模型（无 mmproj）
                modelURL = documentsDirectory.appendingPathComponent(MiniCPMModelConst.modelv526_FileName)
                selectedModelType = .V526TextModel
            }
            
            self.benchLog("[MOEBENCH] checkpoint=model-resolved type=\(selectedModelType) model=\(modelURL?.lastPathComponent ?? "nil") mmproj=\(mmprojURL?.lastPathComponent ?? "nil")")
            // 纯文本模型不需要 mmproj
            guard let modelURL = modelURL,
                  (selectedModelType.isTextOnly || mmprojURL != nil) else {
                DispatchQueue.main.async {
                    hud.mode = .text
                    hud.label.text = L.Home.initFailedDownloadFirst.loc
                    hud.hide(animated: true, afterDelay: 3)
                }
                return
            }

            self.benchLog("[MOEBENCH] checkpoint=guard-passed type=\(selectedModelType)")
            if !selectedModelType.isTextOnly && selectedModelType != .V47MoE && selectedModelType != .V47_1B {
                let expectedMD5: (model: String, mmproj: String)
                switch selectedModelType {
                case .V26MultiModel:
                    expectedMD5 = (MiniCPMModelConst.modelQ4_K_MMD5, MiniCPMModelConst.modelMMProjMD5)
                case .V4MultiModel:
                    expectedMD5 = (MiniCPMModelConst.modelv4_Q4_K_M_MD5, MiniCPMModelConst.modelMMProjv4_MD5)
                case .V46MultiModel:
                    expectedMD5 = (MiniCPMModelConst.modelv46_Q4_K_M_MD5, MiniCPMModelConst.modelMMProjv46_MD5)
                default:
                    expectedMD5 = ("", "")
                }

                guard let mmprojURL,
                      !expectedMD5.model.isEmpty,
                      MBModelArtifactStore.validatePair(
                        modelURL: modelURL,
                        modelMD5: expectedMD5.model,
                        mmprojURL: mmprojURL,
                        mmprojMD5: expectedMD5.mmproj
                      ) else {
                    DispatchQueue.main.async {
                        hud.mode = .text
                        hud.label.text = L.Home.initFailedDownloadFirst.loc
                        hud.hide(animated: true, afterDelay: 3)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self.currentUsingModelType = selectedModelType
                self.mtmdWrapperExample?.currentUsingModelType = selectedModelType
            }
            
            // 加载模型
            if await self.mtmdWrapperExample?.multiModelLoadingSuccess == false {
                if selectedModelType == .V5TextModel || selectedModelType == .V526TextModel {
                    // MiniCPM5 纯文本模型：无 mmproj，走 text-only 初始化路径
                    await self.mtmdWrapperExample?.initializeTextOnly(modelPath: modelURL.path)
                } else if selectedModelType == .V26MultiModel {
                    // V2.6 不走 CoreML / ANE，没有冷启动文案。
                    await self.mtmdWrapperExample?.initialize(modelPath: modelURL.path, mmprojPath: mmprojURL!.path)
                } else if selectedModelType == .V4MultiModel {

                    await self.mtmdWrapperExample?.initialize(modelPath: modelURL.path, mmprojPath: mmprojURL!.path)

                    // warm-up：注入一张全白图触发 mmproj 首次 forward。
                    let whiteImage = UIImage(named: "white")
                    let whiteImageData = whiteImage?.pngData()
                    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
                    let whiteImagePath = documentsPath.appending("/white.png")
                    try? whiteImageData?.write(to: URL(fileURLWithPath: whiteImagePath))
                    _ = await self.mtmdWrapperExample?.addImageInBackground(whiteImagePath)
                } else if selectedModelType == .V46MultiModel {
                    let coremlPath = MiniCPMV46CoreMLBootstrap.resolvedCoreMLPathInDocuments()
                    let nCtx = MBDeviceMemoryProbe.recommendedNCtx
                    await self.mtmdWrapperExample?.initialize(
                        modelPath: modelURL.path,
                        mmprojPath: mmprojURL!.path,
                        coremlPath: coremlPath,
                        nCtx: nCtx
                    )
                } else if selectedModelType == .V47_1B {
                    // MiniCPM-V 4.7 1B：dense，无 experts / 无 MoE / 无 CoreML。
                    guard let artifacts = MiniCPMV47_1BConst.resolveArtifacts(in: documentsDirectory) else {
                        DispatchQueue.main.async {
                            hud.mode = .text
                            hud.label.numberOfLines = 0
                            hud.label.text = "找不到 MiniCPM-V 4.7 1B 文件。请把 \(MiniCPMV47_1BConst.modelFileName) 与 "
                                + "\(MiniCPMV47_1BConst.mmprojFileName) 放进 Documents/\(MiniCPMV47_1BConst.documentsDirName)/"
                            hud.hide(animated: true, afterDelay: 6)
                        }
                        return
                    }
                    // 视觉塔指纹：4.7 1B 的 mmproj 是 minicpmv4_7（与 4.6 的 minicpmv4_6 结构与切片一致）。
                    // 换成别的塔（如 qwen3vl_merger）虽能加载，但会静默改变图像 token 预算、切片滑条失效。
                    do {
                        let vision = try MBCLIPMetadataProbe.readVisionInfo(at: artifacts.mmprojURL)
                        print("MTMDWrapperExample: v47 1B vision tower \(vision.summary)")
                        if !vision.usesLLaVAUHDSlicing {
                            DispatchQueue.main.async {
                                hud.mode = .text
                                hud.label.numberOfLines = 0
                                hud.label.text = "视觉塔不匹配：mmproj 是 \(vision.projectorType)，4.7 1B 需要 minicpmv4_6 / minicpmv4_7。"
                                hud.hide(animated: true, afterDelay: 12)
                            }
                            return
                        }
                    } catch {
                        print("MTMDWrapperExample: v47 1B mmproj 元数据读取失败 \(error.localizedDescription)（继续加载）")
                    }
                    await self.mtmdWrapperExample?.initialize(
                        modelPath: artifacts.modelURL.path,
                        mmprojPath: artifacts.mmprojURL.path,
                        nCtx: MiniCPMV47_1BConst.defaultNCtx,
                        warmup: false
                    )
                } else if selectedModelType == .V47MoE {
                    self.benchLog("[MOEBENCH] checkpoint=enter-v47-branch")
                    // 这里必须和上面选型时用同样的 mmproj 要求，否则纯文本基准
                    // （-moeTextOnly，没有 mmproj）会在这里被 guard 挡掉、
                    // 函数直接 return，表现为"启动后停在半路、日志断掉"。
                    let benchTextOnlyHere = ProcessInfo.processInfo.arguments.contains("-moeTextOnly")
                    guard let artifacts = MiniCPMV47Const.resolveArtifacts(in: documentsDirectory,
                                                                         requireMMProj: !benchTextOnlyHere) else {
                        DispatchQueue.main.async {
                            hud.mode = .text
                            hud.label.numberOfLines = 0
                            hud.label.text = "找不到 MiniCPM-V 4.7 文件，请先安装模型（gguf + mmproj + experts）"
                            hud.hide(animated: true, afterDelay: 4)
                        }
                        return
                    }
                    self.benchLog("[MOEBENCH] checkpoint=experts-problems-before")
                    // 纯 I/O 诊断：不需要 mmproj、不需要走 model/bench 参数。
                    // 直接对 experts 做顺序读 vs 随机读，把 GPU/线程/引擎这些变量排除掉。
                    // 放在 artifacts 绑定之后，因为它需要 expertsURL。
                    if ProcessInfo.processInfo.arguments.contains("-moeBenchIODiag") {
                        setvbuf(stdout, nil, _IONBF, 0)
                        // 从 manifest 读真实参数，保证测的就是引擎遇到的那个模式
                        var stride = 2039808, perExpert = 2039808, experts = 256
                        let mURL = artifacts.expertsURL.appendingPathComponent("manifest.json")
                        if let d = try? Data(contentsOf: mURL),
                           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           let es = root["entries"] as? [[String: Any]] {
                            let routed = es.filter {
                                ["ffn_gate_exps", "ffn_up_exps", "ffn_down_exps"]
                                    .contains($0["tensor_family"] as? String ?? "")
                            }
                            if let e = routed.first {
                                stride = (e["expert_stride"] as? NSNumber)?.intValue ?? stride
                                // 一个 expert 的**完整打包长度**就是 stride（gate|up|down 连续排列）。
                                // 上一版误用了「第一个 family 的结束偏移」，只测到一个 family，
                                // 导致工作集偏小、被 page cache 吃掉。
                                perExpert = stride
                            }
                            if let mc = (root["model"] as? [String: Any])?["expert_count"] as? NSNumber {
                                experts = mc.intValue
                            }
                        }
                        MoeIoDiag.run(expertsDir: artifacts.expertsURL,
                                      stride: stride, perExpert: perExpert,
                                      experts: experts, picks: 4200)   // 与一次 prefill 的 miss 数同量级
                        print("[IODIAG] done")
                        fflush(stdout)
                        exit(0)
                    }
                    let expertsProblems = MiniCPMV47Const.expertsProblems(at: artifacts.expertsURL)
                    self.benchLog("[MOEBENCH] checkpoint=experts-problems-after n=\(expertsProblems.count)")
                    if !expertsProblems.isEmpty {
                        print("MiniCPMV47Const: experts 校验失败 \(expertsProblems.count) 个文件：\n"
                              + expertsProblems.map { "  - " + $0.text }.joined(separator: "\n"))
                        DispatchQueue.main.async {
                            hud.mode = .text
                            hud.label.numberOfLines = 0
                            hud.label.text = "experts 不完整（\(expertsProblems.count) 个文件）：\n"
                                + expertsProblems.prefix(3).map { $0.text }.joined(separator: "\n")
                                + "\n请重新安装模型文件（experts 需与主模型同批）"
                            hud.hide(animated: true, afterDelay: 10)
                        }
                        return
                    }
                    // 基准专用：`-moeTextOnly` 时走纯文本 + experts 路径，完全跳过 mmproj。
                    // 理由：1) 基准是纯文本的，MoE 专家与视觉塔无关；2) 省 ~1GB 常驻；
                    // 3) 自动化环境里可能拿不到那份 1.04GB 的 V4.7 mmproj。
                    // 不影响正常路径：只有显式传该启动参数才生效。
                    self.benchLog("[MOEBENCH] checkpoint=experts-check-done textOnly=\(ProcessInfo.processInfo.arguments.contains("-moeTextOnly"))")
                    if ProcessInfo.processInfo.arguments.contains("-moeTextOnly") {
                        print("MTMDWrapperExample: v47 text-only + experts 路径（-moeTextOnly）")
                        // DSpark：找不到草稿模型就传空，静默关闭投机。
                        let draftPath = MiniCPMV47Const.resolveDraftModelPath(in: documentsDirectory)
                        // 窗口在下面分配，先落 pending，成功后才清。
                        MiniCPMV47Const.markCacheWindowLoadStarted()
                        let winSlots = MiniCPMV47Const.decodeWindow(expertsURL: artifacts.expertsURL)
                            + MiniCPMV47Const.lookaheadPrefetchDepth()
                        await self.mtmdWrapperExample?.initializeTextOnly(
                            modelPath: artifacts.modelURL.path,
                            nCtx: MiniCPMV47Const.defaultNCtx,
                            moeExpertsPath: artifacts.expertsURL.path,
                            moeSlotBank: MiniCPMV47Const.slotBank(),
                            moeDecodeWindow: MiniCPMV47Const.decodeWindow(expertsURL: artifacts.expertsURL),
                            nUbatchOverride: MiniCPMV47Const.nUbatch(),
                            draftModelPath: draftPath,
                            // 必须用 effective*：请求值可能超过窗口容量（见该函数说明）。
                            specDraftNMax: MiniCPMV47Const.effectiveSpecDraftNMax(windowSlots: winSlots)
                        )
                        // 这条路径不落到公共成功点，也要清 pending。
                        MiniCPMV47Const.markCacheWindowLoadOk()
                        await self.updateImageLoadedStatus(true)
                        DispatchQueue.main.async {
                            if selectedModelType == .V47MoE {
                                self.runMoeBenchIfRequested()
                            }
                        }
                        return
                    }

                    // DSpark 开着却走多模态路径 = 内存必爆（窗口 + 草稿 + mmproj ≈ 4150 MiB
                    // > 8 GB iPhone 的 4 GiB 限额），实测在 mmproj 加载阶段被 jetsam 杀且
                    // 日志无 DSpark 报错。要测 DSpark 请用 -moeTextOnly 启动。
                    if MiniCPMV47Const.specDraftNMaxResolved() > 0 {
                        print("[MODEL] WARNING: DSpark 已开启但走的是多模态路径（会加载 mmproj）。"
                              + "窗口 c=32 + 草稿 + mmproj ≈ 4150 MiB > 4096 MiB 限额，"
                              + "极可能被 jetsam 杀（signal 9）。请改用 -moeTextOnly 启动。")
                    }

                    // 视觉塔指纹校验：V4.7 必须配 minicpmv4_6（llava-uhd 切片）塔。
                    // 之前 iPad 上误装成 Qwen3-VL 塔（qwen3vl_merger）时，图会静默走
                    // Qwen 的 dyn_size + image_max_tokens 预算（12MP 图被压到 ~500 token），
                    // 切片滑条全部失效，但界面没有任何异常提示。
                    do {
                        let vision = try MBCLIPMetadataProbe.readVisionInfo(at: artifacts.mmprojURL)
                        print("MTMDWrapperExample: v47 vision tower \(vision.summary)")
                        if !vision.usesLLaVAUHDSlicing {
                            // 顺手删掉错的塔：留着只会在下次冷启动重复同样的困惑。
                            try? FileManager.default.removeItem(at: artifacts.mmprojURL)
                            DispatchQueue.main.async {
                                hud.mode = .text
                                hud.label.numberOfLines = 0
                                hud.label.text = "视觉塔不匹配：mmproj 是 \(vision.projectorType)，V4.7 需要 minicpmv4_6 / minicpmv4_7。\n"
                                    + "已删除 Documents/\(MiniCPMV47Const.documentsDirName)/\(MiniCPMV47Const.mmprojFileName)，"
                                    + "请重新安装模型文件（mmproj 需与主模型同批）"
                                hud.hide(animated: true, afterDelay: 12)
                            }
                            return
                        }
                    } catch {
                        print("MTMDWrapperExample: v47 mmproj 元数据读取失败 \(error.localizedDescription)"
                              + "（继续加载，但无法确认视觉塔类型）")
                    }
                    let draftPath = MiniCPMV47Const.resolveDraftModelPath(in: documentsDirectory)
                    // 同上：窗口在下面分配，先落 pending。
                    MiniCPMV47Const.markCacheWindowLoadStarted()
                    let winSlots = MiniCPMV47Const.decodeWindow(expertsURL: artifacts.expertsURL)
                        + MiniCPMV47Const.lookaheadPrefetchDepth()
                    await self.mtmdWrapperExample?.initialize(
                        modelPath: artifacts.modelURL.path,
                        mmprojPath: artifacts.mmprojURL.path,
                        nCtx: MiniCPMV47Const.defaultNCtx,
                        moeExpertsPath: artifacts.expertsURL.path,
                        moeSlotBank: MiniCPMV47Const.slotBank(),
                        // 多模态路径也要传窗口（默认 0 = 窗口关闭，会拿不到按层缓存收益）。
                        moeDecodeWindow: MiniCPMV47Const.decodeWindow(expertsURL: artifacts.expertsURL),
                        nUbatchOverride: MiniCPMV47Const.nUbatch(),
                        imageMaxTokensOverride: MiniCPMV47Const.defaultImageMaxTokens,
                        warmup: false,
                        draftModelPath: draftPath,
                        specDraftNMax: MiniCPMV47Const.effectiveSpecDraftNMax(windowSlots: winSlots)
                    )
                }

                // 更新模型加载状态为：加载成功
                // 窗口已分配成功（最易触发 jetsam 的一步），清掉安全网 pending。
                MiniCPMV47Const.markCacheWindowLoadOk()
                await self.updateImageLoadedStatus(true)
                NSLog("%@", MBDeviceMemoryProbe.memoryReport("after model load"))

                // 通知 C bridge 当前模型版本，用于选择正确的 assistant prompt prefix
                await self.mtmdWrapperExample?.applyModelVersion()
                if selectedModelType == .V47MoE {
                    // 35a3_hf_v47 的模板默认在 assistant 后开 <think>；App 强制关掉，
                    // 避免几百 token 耗在思考链里。
                    await self.mtmdWrapperExample?.setEnableThinking(false)
                } else {
                    await self.mtmdWrapperExample?.setEnableThinking(
                        UserDefaults.standard.bool(forKey: "enable_thinking")
                    )
                }
            }
            
            // 检查模型加载状态
            DispatchQueue.main.async {
                guard let wrapper = self.mtmdWrapperExample else {
                    hud.hide(animated: true)
                    return
                }
                if wrapper.multiModelLoadingSuccess == false {
                    hud.mode = .text
                    hud.label.numberOfLines = 0
                    let detail = wrapper.errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if selectedModelType == .V47MoE {
                        hud.label.text = detail.isEmpty
                            ? "MiniCPM-V 4.7 加载失败（文件还在，看 Xcode 控制台）"
                            : "加载失败：\(detail)"
                    } else {
                        hud.label.text = detail.isEmpty ? L.Home.initFailedDownloadFirst.loc : "加载失败：\(detail)"
                    }
                    hud.hide(animated: true, afterDelay: 5)
                } else {
                    hud.mode = .text
                    hud.label.numberOfLines = 0
                    hud.label.text = selectedModelType == .V47MoE
                        ? "加载完成"
                        : L.Home.initDone.loc
                    hud.hide(animated: true, afterDelay: 2)

                    // 自动化基准：只在 `-moeBench` 启动参数下触发。
                    // 放在这里是因为此时模型已 init 完成、depth 已由启动参数落地，
                    // 后面走的是和手动一模一样的 addText → startGeneration 链路。
                    if selectedModelType == .V47MoE {
                        self.runMoeBenchIfRequested()
                    }
                }
            }
        }
    }

}

// MARK: - 跳层预读基准（纯命令行驱动，不依赖任何 UI 操作）

extension MBHomeViewController {

    /// 基准日志。stdout 在非 tty（`devicectl --console` 就是管道）下是块缓冲的，
    /// 进程被超时杀掉时缓冲会丢；这里显式 flush，保证日志随时可读。
    fileprivate func benchLog(_ s: String) {
        print(s)
        fflush(stdout)
    }

    /// 启动参数取值。用于基准，避免走设置页滑条 —— 手拨滑条不可复现，
    /// 而且实测的 depth 需要和设备上的实际取值严格对应才能下结论。
    private func benchIntArg(_ args: [String], _ name: String) -> Int? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    private func benchStringArg(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `-moeBench` 触发。默认固定 32 步、固定 prompt，跑完打印一行 `[MOEBENCH]` 结果后退出。
    ///
    /// 为什么固定步数：生成到 EOG 才停的话，不同 depth / 不同设备的输出长度不同，
    /// decode t/s 会把"生成了多长"这一项混进来，跨配置不可比。
    ///
    /// 结果行字段：depth（生效的预读深度）、prefill/decode 的 token 数与毫秒数、
    /// 两者 t/s、以及桥接层实际生效的 Kp/Kd（用来确认 top-8 前提没被破坏）。
    func runMoeBenchIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-moeBench") else { return }

        guard let wrapper = self.mtmdWrapperExample else {
            print("[MOEBENCH] error: wrapper 不存在")
            exit(2)
        }

        let tokens = benchIntArg(args, "-moeBenchTokens") ?? 32
        // 倍乘默认 prompt：用来做长 prefill。专家覆盖率随 token 数上升
        // （62 token 只覆盖 105/256，512 token 接近全覆盖），而覆盖率决定
        // 层内读是否接近连续 —— 这正是区分「随机读惩罚」和「闪存带宽上限」的关键。
        let mul = benchIntArg(args, "-moeBenchPromptMul") ?? 1
        let basePrompt = benchStringArg(args, "-moeBenchPrompt") ?? MoeBenchDefaultPrompt
        let prompt = mul > 1
            ? Array(repeating: basePrompt, count: mul).joined(separator: "\n")
            : basePrompt
        let t0 = Date()
        func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(t0)) }
        // 重复轮数：同一份 prompt 连续 prefill 多次。
        // 用来分离「冷闪存」和「OS page cache 命中」—— 第 1 轮是冷的，
        // 之后若明显变快，说明那部分速率来自缓存而不是闪存，
        // 也就给出了「自己做显式缓存」的收益上限。
        let repeats = benchIntArg(args, "-moeBenchRepeat") ?? 1
        benchLog("[MOEBENCH] phase=enter depth=\(self.mtmdWrapperExample?.appliedLookaheadPrefetchDepth ?? -1) tokens=\(tokens) repeats=\(repeats) t=\(elapsed())")

        Task { @MainActor in
            // `mtmdWrapper` 是 MTMDWrapperExample 的 internal 成员，模块内可见；
            // 固定步数与 lastPerf 都挂在它上面。
            let inner = wrapper.mtmdWrapper
            inner.decodeTokenLimit = tokens

            // 注意：**不要**调 wrapper.reset()。它内部是 mb_mtmd_free + 重建，会把刚 init
            // 好的上下文销毁（实测日志：~llama_context → 上下文已重置 → prefill 必失败）。
            // App 刚加载完，状态本来就是干净的。
            // 常驻基线：模型 + slot bank + KV/compute 都已分配，还没跑任何一帧。
            // 这是内存预算的起点 —— 要和它比才知道 bank 还能扩多少。
            benchLog(MBDeviceMemoryProbe.memoryReport("after load"))
            for round in 1...max(1, repeats) {
                if round > 1 {
                    // 只清 KV、保留 context（等价于 App 的「新对话」）。
                    wrapper.clearKVCacheForNewTurn()
                }
                benchLog("[MOEBENCH] phase=prefill-start round=\(round) t=\(elapsed())")
                let ok = await wrapper.addTextInBackground(prompt)
                benchLog("[MOEBENCH] phase=prefill-done round=\(round) ok=\(ok) t=\(elapsed())")
                guard ok else {
                    benchLog("[MOEBENCH] error: prefill 失败 round=\(round)")
                    benchLog("[MOEBENCH] depth=\(MiniCPMV47Const.lookaheadPrefetchDepth()) want_tokens=\(tokens) FAILED")
                    exit(2)
                }

                benchLog("[MOEBENCH] phase=decode-start round=\(round) t=\(elapsed())")
                await wrapper.startGeneration()

                // startGeneration 只是起任务，这里等它跑完；带上限防挂死。
                var waited = 0
                while inner.generationState == .generating && waited < 1200 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                let pt = inner.lastPerf
                let prTps = pt.prefill_ms > 0 ? Double(pt.prefill_tokens) / (pt.prefill_ms / 1000.0) : 0
                let deTps = pt.decode_ms  > 0 ? Double(pt.decode_tokens)  / (pt.decode_ms  / 1000.0) : 0
                benchLog(MBDeviceMemoryProbe.memoryReport("after round \(round)"))
                benchLog(String(
                    format: "[MOEBENCH] round=%d/%d depth=%d prefill_tokens=%d prefill_ms=%.1f prefill_tps=%.2f "
                          + "decode_tokens=%d decode_ms=%.1f decode_tps=%.2f Kp=%d Kd=%d t=%@",
                    round, repeats, self.mtmdWrapperExample?.appliedLookaheadPrefetchDepth ?? -1,
                    Int(pt.prefill_tokens), pt.prefill_ms, prTps,
                    Int(pt.decode_tokens), pt.decode_ms, deTps,
                    Int(pt.moe_k_prefill), Int(pt.moe_k_decode), elapsed()))
            }
            benchLog("[MOEBENCH] done t=\(elapsed())")
            exit(0)
        }
    }
}

/// 固定基准 prompt。要求模型产出足够长、结构稳定的输出，好在 32 步内不撞 EOG。
/// 内容本身不重要 —— 跨配置比的是同一段文本下的 t/s 与盘读字节。
let MoeBenchDefaultPrompt = """
Please list the numbers from 1 to 200, one per line, and after each number write a short \
English sentence describing what that number is commonly used for in everyday life. \
Keep the sentences simple and do not stop early.
"""

// MARK: - 纯 I/O 诊断（不加载模型、不碰 GPU）

import Foundation

/// 直接对 experts 文件做读测试，用来把「访问模式」和「GPU/线程/引擎」这些变量彻底分开。
///
/// 为什么需要它：引擎侧的日志显示 prefill 的 I/O 钉在 1.68 GB/s，而 decode 能到
/// 3.9 GB/s，单流速率差 3.3 倍。但那条路径上同时有 GPU 争带宽、线程调度、Metal
/// 共享内存写入等变量，无法判断到底是谁的问题。这里用最朴素的 FileHandle 读，
/// 只比较**顺序读**和**真实随机模式**，其余条件完全相同。
///
/// 用法：`-moeBenchIODiag`（不需要 -moeBench，模型加载完就能跑）
enum MoeIoDiag {

    /// 用 POSIX pread，而不是 Foundation 的 FileHandle.read ——
    /// 引擎走的就是 preadv，用同一类系统调用比较才有意义，
    /// 也避免 Data 分配/拷贝干扰测量。
    private static func preadFull(_ fd: Int32, _ off: Int, _ n: Int, _ buf: inout [UInt8]) -> Int {
        buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var done = 0
            while done < n {
                let r = pread(fd, base.advanced(by: done), n - done, off_t(off + done))
                if r <= 0 { break }
                done += r
            }
            return done
        }
    }

    private static func openRead(_ url: URL) -> Int32 {
        url.path.withCString { open($0, O_RDONLY) }
    }

    /// 顺序读：多个文件连续读，总量大且冷。
    static func sequential(_ urls: [URL], chunkBytes: Int) -> (mib: Double, ms: Double) {
        var buf = [UInt8](repeating: 0, count: chunkBytes)
        var total = 0
        let t0 = Date()
        for url in urls {
            let fd = openRead(url)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size > 0 else { continue }
            var off = 0
            while off < size {
                let n = min(chunkBytes, size - off)
                let got = preadFull(fd, off, n, &buf)
                if got <= 0 { break }
                total += got
                off += got
            }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        return (Double(total) / 1048576.0, ms)
    }

    /// 随机读：**铺满全部 layer 文件**，每个 expert 读完整打包长度（gate|up|down）。
    ///
    /// 工作集必须接近真实 prefill（~8 GB），否则会被 page cache 吃掉 ——
    /// 上一版只读一个 498 MB 文件，测出 6 GB/s 的「缓存速率」而非闪存速率。
    static func scattered(_ urls: [URL], stride: Int, perExpert: Int,
                          experts: Int, picks: Int) -> (mib: Double, ms: Double) {
        guard !urls.isEmpty else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: perExpert)
        // 每个文件一个 fd，模拟引擎按层缓存 fd 的行为
        let fds = urls.map { openRead($0) }
        defer { for fd in fds where fd >= 0 { close(fd) } }
        let live = fds.enumerated().filter { $0.element >= 0 }
        guard !live.isEmpty else { return (0, 0) }

        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ m: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(m))
        }
        var total = 0
        let t0 = Date()
        for i in 0..<picks {
            // 轮转所有层文件；层 0/1 是 498MB、其余 432MB，混合更接近真实分布
            let fd = live[i % live.count].element
            let off = next(experts) * stride
            total += preadFull(fd, off, perExpert, &buf)
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        return (Double(total) / 1048576.0, ms)
    }

    /// **读粒度扫描**：直接测「把 r 个相邻专家一次读完」是否比「逐个读」快。
    ///
    /// 这是「合并相邻专家的读」的可行性前置实验 —— 不动引擎，只问闪存一件事：
    /// 增大单次读的长度，吞吐会不会上去。
    /// 引擎侧的统计显示 prefill 的 avg_run=2.0、max_run=15（专家连号程度），
    /// 所以这里扫 r = 1/2/4/8/16 就能知道「合并到多大才有收益」。
    ///
    /// 算法上完全复刻真实模式：从随机起点读 r 个**连续**专家（它们在文件里
    /// 就是连续的一段，长度 r * stride），轮转所有 layer 文件以撑大工作集。
    static func granularitySweep(_ urls: [URL], stride: Int, experts: Int,
                                 totalExperts: Int, runs rValues: [Int]) {
        func log(_ s: String) { print(s); fflush(stdout) }
        let fds = urls.map { openRead($0) }
        defer { for fd in fds where fd >= 0 { close(fd) } }
        let live = fds.filter { $0 >= 0 }
        guard !live.isEmpty else { return }

        let maxRun = min(rValues.max() ?? 1, experts - 1)
        guard maxRun >= 1 else { return }
        var buf = [UInt8](repeating: 0, count: maxRun * stride)

        for r in rValues where r >= 1 && r <= experts - 1 {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next(_ m: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(m))
            }
            var remaining = totalExperts
            var total = 0
            var reads = 0
            let t0 = Date()
            var fi = 0
            while remaining > 0 {
                let run = min(r, remaining)
                let maxStart = experts - run
                if maxStart <= 0 { break }
                let off = next(maxStart) * stride
                total += preadFull(live[fi % live.count], off, run * stride, &buf)
                reads += 1
                fi += 1
                remaining -= run
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            let mib = Double(total) / 1048576.0
            log(String(format: "[IODIAG] r=%-2d  %8.1f MiB %8.1f ms %7.1f MiB/s  syscalls=%d  avg_read=%.2f MiB",
                       r, mib, ms, ms > 0 ? mib / (ms / 1000.0) : 0, reads,
                       reads > 0 ? mib / Double(reads) : 0))
        }
    }

    static func run(expertsDir: URL, stride: Int, perExpert: Int, experts: Int, picks: Int) {
        func log(_ s: String) { print(s); fflush(stdout) }

        let all = (0..<40).compactMap { i -> URL? in
            let u = expertsDir.appendingPathComponent(String(format: "layer_%03d.bin", i))
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        log("[IODIAG] experts=\(expertsDir.path) files=\(all.count)")
        log("[IODIAG] stride=\(stride) perExpert=\(perExpert) experts=\(experts) picks=\(picks)")
        log("[IODIAG] 预期随机读总量 = \(picks * perExpert / 1048576) MiB（prefill 实测 7657 MiB）")
        guard all.count >= 8 else { log("[IODIAG] layer 文件不足"); return }

        // 顺序读只用前 4 个文件；随机读用**全部** 40 个 —— 两者不重叠，互不污染 cache。
        let seqUrls = Array(all.prefix(4))
        let (sMib, sMs) = sequential(seqUrls, chunkBytes: 4 << 20)
        log(String(format: "[IODIAG] sequential   %8.1f MiB %8.1f ms %7.1f MiB/s  (冷, %d 文件顺序)",
                   sMib, sMs, sMs > 0 ? sMib / (sMs / 1000.0) : 0, seqUrls.count))

        let (rMib, rMs) = scattered(all, stride: stride, perExpert: perExpert,
                                    experts: experts, picks: picks)
        log(String(format: "[IODIAG] scattered    %8.1f MiB %8.1f ms %7.1f MiB/s  (冷, 40 文件轮转)",
                   rMib, rMs, rMs > 0 ? rMib / (rMs / 1000.0) : 0))

        // 读粒度扫描：回答「合并相邻专家的读能拿到多少」
        log("[IODIAG] --- 读粒度扫描（r 个相邻专家一次读完）---")
        granularitySweep(all, stride: stride, experts: experts,
                         totalExperts: picks, runs: [1, 2, 4, 8, 16])
    }
}
