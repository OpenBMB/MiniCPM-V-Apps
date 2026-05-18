//
//  MBHomeViewController+ImageProcess.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/27.
//

import Foundation
import UIKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

/// 图片 prefill 阶段的最终 UI 状态。
///
/// 用来在 prepareLoadModelAddImageToCell 的兜底分支里区分"成功 / 超时 /
/// 失败 / 跳过"，分别在 cell 的 performLog 里写不同文案。把这个 enum 抽到
/// extension 外面，避免和 MBHomeViewController 类体里的其它 nested type 冲突。
enum ImagePrefillUIStatus {
    case succeeded
    case timeout
    case failed(String)
    case skipped
}

extension MBHomeViewController {

    // MARK: - 图片 embed & clip
    
    /// 异步更新当前选中的（应用）模型的类型（例如语言模型 还是 多模态模型）
    func updateCurrentUsingModelType(_ type: CurrentUsingModelTypeV2) async {
        self.currentUsingModelType = type
    }
    
    /// 使用 用户选择的模型 和 image 初始化模型
    public func prepareLoadModelAddImageToCell() {
        Task.detached(priority: .userInitiated) {
            // 一次只加载一张图片并让模型 embedding 完成后，才能再加载另一张图片。
            // uploadSingleImageToModel 在 prefill 期间被置为 true，把
            // processImageAndTextMixModeSendLogic / 重复选图都阻断掉，防止两个
            // mtmd 操作并发跑同一个 ctx（n_past 状态会乱、生成会"没回复"）。
            if await !self.uploadSingleImageToModel {

                await self.updateSingleImageUploadAndProcessStatus(true)

                await self.startLogTimer()

                // 真实耗时用墙钟单独计量，比从 main RunLoop 上 logTimer
                // 0.1s tick 累加更稳：prefill 期间 main runloop 上可能
                // 跑了 cell.bindImageWith / 加载动画等，Timer fire 会少计 tick，
                // 之前 cell 上显示"预处理耗时：0.0s"就是这个原因。
                let processStart = Date()

                // 用枚举把 prefill 的最终状态记下来，由 finalize 兜底统一刷 UI。
                // 这样无论 await 抛错（ANE 加载失败）还是超时（CoreML hang），
                // cell 上一定会被更新成可读的状态，不会停在"图片有但没耗时"。
                var status: ImagePrefillUIStatus = .skipped

                if let imgPath = await self.outputImageURL?.path {
                    do {
                        if let example = await self.mtmdWrapperExample {
                            // 模型尚未加载完成就 prefill，底层会抛
                            // MTMDError.contextNotInitialized，UI 上就是难看的
                            // "上下文未初始化，请先调用 initialize…"。这里和视频
                            // 路径 (MBHomeViewController+CaptureVideo.swift:119)
                            // 对齐，先做一次状态 gating，给用户一个明确可读的
                            // "模型尚未加载完成"提示，避免误以为 App 出 bug。
                            let modelReady = await example.multiModelLoadingSuccess
                            if modelReady {
                                try await example.addImageInBackgroundThrowing(imgPath)
                                status = .succeeded
                                print("[UI]addImage: \(imgPath) ok")
                            } else {
                                status = .failed("模型尚未加载完成，请稍候")
                                print("[UI]addImage skip: model not loaded yet")
                            }
                        } else {
                            status = .failed("MTMD wrapper not ready")
                        }
                    } catch let MTMDError.timeout(msg) {
                        status = .timeout
                        print("[UI]addImage timeout: \(msg)")
                    } catch {
                        status = .failed(error.localizedDescription)
                        print("[UI]addImage error: \(error)")
                    }
                }

                let elapsed = Date().timeIntervalSince(processStart)
                await self.finalizeImagePrefillUI(status: status, elapsed: elapsed)
                await self.updateSingleImageUploadAndProcessStatus(false)
            }
        }
    }

    /// 统一把 prefill 结束后的 UI 兜底刷新出来：
    /// - stopLogTimer
    /// - 写 cell 的 performLog（成功展示耗时；失败 / 超时显式提示用户）
    /// - 清掉 outputImageView 的预览图
    ///
    /// `elapsed` 由调用方用墙钟（Date()）量出来传进来。早期版本是从
    /// `logTimeSecond` 读，但那个值依赖 main RunLoop 上的 0.1s Timer fire，
    /// 在 prefill 期间 main 被 cell 渲染挡住时会少 tick 甚至 0 tick，UI 上
    /// 就显示成"预处理耗时：0.0s"。墙钟值永远正确。
    ///
    /// 这是一个 @MainActor 函数，所有 UI 操作都在 main 上跑。
    @MainActor
    func finalizeImagePrefillUI(status: ImagePrefillUIStatus, elapsed: TimeInterval) {
        self.stopLogTimer()

        if self.dataArray.count > 0,
           let latestCell = self.tableView.cellForRow(at: IndexPath(row: self.dataArray.count - 1, section: 0)) as? MBImageTableViewCell {
            if latestCell.model?.role == "user",
               latestCell.model?.contentImage != nil {

                let size = MBHomeViewController.formatBytesAsKBMB(self.outputImageFileSize)

                // 不同状态下渲染不同的 perfLog 文案。timeout / failed 用更显眼
                // 的文案让用户直观感知到 ANE / CoreML 出问题了，而不是"卡住没反应"。
                let perfLog: String
                switch status {
                case .succeeded:
                    let timeInSeconds = String(format: "%.1f", elapsed)
                    perfLog = "\t\t预处理耗时：\(timeInSeconds)s"
                case .timeout:
                    perfLog = "\t\t预处理超时（>\(Int(MTMDWrapper.defaultPrefillTimeoutSeconds))s）"
                case .failed(let reason):
                    let trimmed = reason.count > 24 ? String(reason.prefix(24)) + "…" : reason
                    perfLog = "\t\t预处理失败：\(trimmed)"
                case .skipped:
                    perfLog = "\t\t预处理已跳过"
                }

                // 处理完成后，这个值总是 -1（让进度条收尾到 100%）
                latestCell.model?.processProgress = -1

                latestCell.model?.performLog = "\(Int(self.outputImageView.image?.size.width ?? 0))x\(Int(self.outputImageView.image?.size.height ?? 0)) (\(size)) \(perfLog)"
                latestCell.bindImageWith(data: latestCell.model)
            }
        }

        // 使用过一次就清除
        self.outputImageView.image = nil
    }
    
    /// 更新多图模型加载状态
    func updateImageLoadedStatus(_ status: Bool) async {
        self.imageLoaded = status
    }
    
    /// 用户在 toolbar 选择单张图上传时 上传状态
    func updateSingleImageUploadAndProcessStatus(_ status: Bool) async {
        self.uploadSingleImageToModel = status
    }
}

extension MBHomeViewController {

    /// 选完图后的预处理：把从 PHPicker 拿到的本地副本路径 / 选中 UIImage / 大小
    /// 全部 reconcile 进 outputImageView + outputImageURL + outputImageFileSize。
    ///
    /// 之前签名是 `(result: PickerResult?, urls: [URL], iv: UIImage)`，依赖 HXPhotoPicker
    /// 的 PickerResult 提供 fileSize；切到 PHPicker 之后 picker 不直接给文件大小，
    /// 我们在 didFinishPicking 那边自己 stat 一下文件，用独立的 `fileSize` 形参喂进来。
    public func selectedImagePreprocess(fileSize: UInt64, urls: [URL], iv: UIImage) {

        // 选中的图片大小（KB，MB）
        self.outputImageFileSize = fileSize

        // 重置这个变量
        self.hasImageAndTextConversation = false

        // 最近一次选中的图片
        self.outputImageView.image = iv

        // 加一个处理 heic 格式的逻辑
        let tmpURL = urls.first

        if tmpURL?.absoluteString.lowercased().contains(".heic") == true {
            if let url = self.saveImageToCache(image: iv,
                                               fileName: "myImage_heic_\(self.outputImageFileSize)_\(arc4random()).jpeg", compressionQuality: 0.5) {
                self.outputImageURL = url
                debugLog("选择了 .heic 格式图片。")
            }
        } else if let tmpURL = tmpURL {
            if let imageData = try? Data(contentsOf: tmpURL) {
                if imageData.isWebP {
                    if let url = self.saveImageToCache(image: iv,
                                                       fileName: "myImage_webp_\(self.outputImageFileSize)_\(arc4random()).png") {
                        self.outputImageURL = url
                        debugLog("选择了 .webp 格式图片。")
                    }
                } else {
                    self.outputImageURL = tmpURL
                }
            } else {
                self.outputImageURL = tmpURL
            }
        } else {
            self.outputImageURL = urls.first
        }
    }

    /// 输入栏「选择图片」按钮点击事件
    ///
    /// 切到 PHPicker 之后实现思路：
    ///   1. 配置 PHPickerConfiguration（filter = .images / .any(of:) ; selectionLimit = 1）
    ///   2. present 系统 picker
    ///   3. 用户选完之后，PHPickerViewControllerDelegate 在 didFinishPicking 里
    ///      异步把 itemProvider 的内容 export 成本地 URL（PHPicker 给的路径 picker
    ///      dismiss 后会失效，必须 copy 到自己的 Caches/Tmp）
    ///   4. 主线程上喂回 selectedImagePreprocess + appendImageDataToCellWith ...
    @objc public func handleChooseImage(_ sender: UIButton) {

        if thinking {
            self.showErrorTips("处理中，请稍等")
            return
        }

        // 上一张图还在 mb_mtmd_prefill_image 中，禁止并发选第二张：
        // 不然两次 prefill_image 在 DispatchQueue.global 上并发跑同一个
        // mtmd_context，n_past 与图像 token KV 会全部错位。
        if self.uploadSingleImageToModel {
            self.showErrorTips("上一张图片预处理中，请稍等")
            return
        }

        // PHPickerConfiguration() 默认 init —— **不**关联 PHPhotoLibrary.shared()。
        // 关联 photoLibrary 是给"返回 PHAsset 而不只是 itemProvider"用的，我们这边
        // 全程走 itemProvider 不需要 PHAsset。少这一关联同时省掉 PHPhotoLibrary
        // 首次实例化时同步加载相册 metadata 的几十 ms（用户感受就是"点图标按钮
        // 总卡一下才弹出"）。代价：picker 选回的 PHPickerResult.assetIdentifier
        // 永远 nil —— 不影响我们用 itemProvider 走文件路径。
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        // 不让 picker 私下转码（高分图我们要拿原图 byte，jpeg/heic/png 自己识别）
        config.preferredAssetRepresentationMode = .current
        // 收起态可选图+视频；全屏编辑态只允许图片
        config.filter = self.fullscreenEditor
            ? .images
            : .any(of: [.images, .videos])

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        self.present(picker, animated: true)
    }
}

// MARK: - PHPickerViewControllerDelegate

extension MBHomeViewController: PHPickerViewControllerDelegate {

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let provider = results.first?.itemProvider else {
            // 用户取消
            debugLog("-->> PHPicker cancelled or empty selection")
            return
        }

        let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)

        if isVideo {
            handlePickedVideo(provider: provider)
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            handlePickedImage(provider: provider)
        } else {
            debugLog("-->> PHPicker: unsupported item provider, no UIImage / movie")
        }
    }

    /// 把图片 provider 的内容 export 成"UIImage + 本地 cache 路径"，再走原有流程。
    ///
    /// 两步异步：
    ///   - loadObject(ofClass: UIImage.self)  — 拿到 UIImage 给 UI 预览
    ///   - loadFileRepresentation(typeIdentifier: image)
    ///                                        — 拿到原文件 byte 流，copy 到我们自己的
    ///                                          tmp 路径再喂给 mtmd（mtmd 需要文件路径不是 UIImage）
    private func handlePickedImage(provider: NSItemProvider) {
        provider.loadObject(ofClass: UIImage.self) { [weak self] obj, err in
            guard let self = self else { return }
            if let err = err {
                debugLog("-->> PHPicker loadObject(UIImage) error: \(err.localizedDescription)")
            }
            guard let img = obj as? UIImage else {
                debugLog("-->> PHPicker loadObject returned non-UIImage")
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] tmpURL, fileErr in
                guard let self = self else { return }
                if let fileErr = fileErr {
                    debugLog("-->> PHPicker loadFileRepresentation error: \(fileErr.localizedDescription)")
                }
                guard let tmpURL = tmpURL else {
                    debugLog("-->> PHPicker did not provide a file URL for image")
                    return
                }

                // PHPicker 给的 URL 在闭包返回后即被框架删除，必须立刻 copy。
                let ext = tmpURL.pathExtension.isEmpty ? "jpg" : tmpURL.pathExtension
                let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("phpicker_img_\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: tmpURL, to: dest)
                } catch {
                    debugLog("-->> PHPicker copy image to tmp failed: \(error.localizedDescription)")
                    return
                }

                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0

                DispatchQueue.main.async {
                    self.selectedImagePreprocess(fileSize: UInt64(size), urls: [dest], iv: img)
                    self.dispatchAfterImagePicked(isVideo: false)
                }
            }
        }
    }

    /// 把视频 provider export 成本地 .mov 文件，缓存到 cachedVideoURLs，再走抽帧流程。
    private func handlePickedVideo(provider: NSItemProvider) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] tmpURL, fileErr in
            guard let self = self else { return }
            if let fileErr = fileErr {
                debugLog("-->> PHPicker loadFileRepresentation(video) error: \(fileErr.localizedDescription)")
            }
            guard let tmpURL = tmpURL else {
                debugLog("-->> PHPicker did not provide a file URL for video")
                return
            }

            let ext = tmpURL.pathExtension.isEmpty ? "mov" : tmpURL.pathExtension
            let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("phpicker_vid_\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.copyItem(at: tmpURL, to: dest)
            } catch {
                debugLog("-->> PHPicker copy video to tmp failed: \(error.localizedDescription)")
                return
            }

            // 视频要给 UI 一个缩略图（取第一帧），因为我们 cell 上 UIImageView 显示的是
            // 视频封面而不是 mov 本身。失败的话用纯黑兜底，不挡住后续抽帧流程。
            let thumbnail = MBHomeViewController.firstFrameThumbnail(of: dest)
                ?? MBHomeViewController.placeholderThumbnail()

            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0

            DispatchQueue.main.async {
                self.selectedImagePreprocess(fileSize: UInt64(size), urls: [dest], iv: thumbnail)
                self.dispatchAfterImagePicked(isVideo: true)
            }
        }
    }

    /// 选图 / 选视频统一的 UI + 推理后续处理（之前在 handleChooseImage 闭包里 inline 写的，
    /// 抽出来让两条 provider 路径都能共用）。
    @MainActor
    private func dispatchAfterImagePicked(isVideo: Bool) {
        guard self.outputImageURL != nil, self.outputImageView.image != nil else { return }

        let videoURLString: String? = isVideo ? self.outputImageURL?.absoluteString : nil
        self.appendImageDataToCellWith(image: self.outputImageView.image, imageURL: videoURLString)

        // 滚动到底部
        self.tableViewScrollToBottom()

        self.mtmdWrapperExample?.performanceLog = ""

        if isVideo {
            // 视频：缓存本地 URL（用于点击预览），并启动抽帧 → mtmd 视频路径
            if let keyStr = self.outputImageURL?.absoluteString, !keyStr.isEmpty,
               let videoURL = self.outputImageURL {
                self.cachedVideoURLs[keyStr] = videoURL
                debugLog("-->> selected.video.url = \(videoURL.path)")

                Task {
                    // 视频抽帧上限：MiniCPM-V 4.6 走 64 帧（1fps，超长则均匀抽帧），
                    // 老的 V2.6 / V4.0 维持 16 帧上限避免回归（旧 demo 时代的视频路径）。
                    let maxFrames = (self.mtmdWrapperExample?.currentUsingModelType == .V46MultiModel)
                        ? 64
                        : 16
                    let extractor = MBVideoFrameExtractor(videoURL: videoURL,
                                                          fps: 1,
                                                          supportTotalFrames: maxFrames)
                    await extractor.extractFrames { [weak self] images in
                        if let images = images {
                            Task { await self?.processVideoFrame(images: images) }
                        }
                    }
                }
            }
        } else {
            // 普通图片直接走 prefill 路径
            if self.outputImageURL?.absoluteString.contains(".mp4") == false ||
                self.outputImageURL?.absoluteString.contains(".mov") == false {
                self.prepareLoadModelAddImageToCell()
            }
        }
    }

    /// 取本地视频文件的第一帧作为缩略图（同步实现，PHPicker 路径下用一次性，无须 cache）。
    static func firstFrameThumbnail(of url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        do {
            let cgImage = try generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600),
                                                    actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            debugLog("-->> firstFrameThumbnail failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// firstFrameThumbnail 失败时的兜底封面（纯黑 320×240）。仅给 cell UIImageView 占位用，
    /// 不参与模型推理。
    static func placeholderThumbnail() -> UIImage {
        let size = CGSize(width: 320, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
