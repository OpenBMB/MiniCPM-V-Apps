//
//  MBOcrModelDownloadManager.swift
//  MiniCPM-V-demo
//
//  OCR 模型下载管理器（三段下载：LLM + mmproj + layout ONNX）
//

import Foundation
import UIKit

/// OCR 模型下载管理器单例
class MBOcrModelDownloadManager: NSObject {

    // MARK: - 单例实现

    @MainActor static let shared = MBOcrModelDownloadManager()

    private override init() {
        super.init()
    }

    // MARK: - 属性

    private var mtmdWrapperExample: MTMDWrapperExample?

    var llmManager: MBModelDownloadHelperV2?
    var mmprojManager: MBModelDownloadHelperV2?
    var layoutManager: MBModelDownloadHelperV2?

    var progressHandler: ((String, CGFloat) -> Void)?
    var completionHandler: ((String, Bool) -> Void)?
    var detailedProgressHandler: ((DownloadProgressInfo) -> Void)?

    // MARK: - 防重复调用机制

    private var downloadStates: [String: DownloadStatus] = [:]
    private var downloadProgressCache: [String: DownloadProgressInfo] = [:]
    private var downloadStartTimes: [String: Date] = [:]
    private var lastDownloadedBytes: [String: Int64] = [:]
    private let downloadQueue = DispatchQueue(label: "com.minicpm.ocr.download", qos: .userInitiated)

    private func isDownloading(_ modelKey: String) -> Bool {
        return downloadQueue.sync { downloadStates[modelKey] == .downloading }
    }

    private func setDownloadStatus(_ status: DownloadStatus, for modelKey: String) {
        downloadQueue.sync {
            downloadStates[modelKey] = status
            if status == .downloading { downloadStartTimes[modelKey] = Date() }
        }
    }

    private func updateDownloadProgress(_ progress: CGFloat, for modelKey: String, modelName: String, downloadedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            let currentTime = Date()
            let startTime = self.downloadStartTimes[modelKey] ?? currentTime
            let timeElapsed = currentTime.timeIntervalSince(startTime)

            var speed: Double = 0
            if let lastBytes = self.lastDownloadedBytes[modelKey], timeElapsed > 0 {
                speed = Double(downloadedBytes - lastBytes) / timeElapsed
            }
            self.lastDownloadedBytes[modelKey] = downloadedBytes

            var estimatedTimeRemaining: TimeInterval = 0
            if speed > 0, totalBytes > downloadedBytes {
                estimatedTimeRemaining = Double(totalBytes - downloadedBytes) / speed
            }

            let progressInfo = DownloadProgressInfo(
                modelName: modelName,
                status: self.downloadStates[modelKey] ?? .notStarted,
                progress: progress,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                speed: speed,
                estimatedTimeRemaining: estimatedTimeRemaining
            )
            self.downloadProgressCache[modelKey] = progressInfo
            DispatchQueue.main.async {
                self.detailedProgressHandler?(progressInfo)
            }
        }
    }

    // MARK: - 公共方法

    func setupDownloadManager(with wrapper: MTMDWrapperExample) {
        self.mtmdWrapperExample = wrapper
        setupModels()
    }

    private func setupModels() {
        guard mtmdWrapperExample != nil else { return }

        llmManager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample!,
            modelName: MiniCPMModelConst.ocr_LLMFileName,
            modelUrl: MiniCPMModelConst.ocr_LLMURLString,
            filename: MiniCPMModelConst.ocr_LLMFileName,
            backupModelUrl: MiniCPMModelConst.ocr_LLMBackUpURLString
        )

        mmprojManager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample!,
            modelName: MiniCPMModelConst.ocr_MMProjFileName,
            modelUrl: MiniCPMModelConst.ocr_MMProjURLString,
            filename: MiniCPMModelConst.ocr_MMProjFileName,
            backupModelUrl: MiniCPMModelConst.ocr_MMProjBackUpURLString
        )

        layoutManager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample!,
            modelName: MiniCPMModelConst.ocr_LayoutFileName,
            modelUrl: MiniCPMModelConst.ocr_LayoutURLString,
            filename: MiniCPMModelConst.ocr_LayoutFileName,
            backupModelUrl: MiniCPMModelConst.ocr_LayoutBackUpURLString
        )

        reconcileStatusFromDisk()
        restoreDownloadProgress()
    }

    func reconcileStatusFromDisk() {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default

        llmManager?.status    = fm.fileExists(atPath: docs.appendingPathComponent(MiniCPMModelConst.ocr_LLMFileName).path)    ? "downloaded" : "download"
        mmprojManager?.status = fm.fileExists(atPath: docs.appendingPathComponent(MiniCPMModelConst.ocr_MMProjFileName).path) ? "downloaded" : "download"
        layoutManager?.status = fm.fileExists(atPath: docs.appendingPathComponent(MiniCPMModelConst.ocr_LayoutFileName).path) ? "downloaded" : "download"
    }

    private func restoreDownloadProgress() {
        guard let info = FDownLoaderManager.shareInstance().downLoaderInfo else { return }

        let llmKey = String(stringLiteral: MiniCPMModelConst.ocr_LLMURLString).md5() ?? ""
        if let obj = info[llmKey] as? FDownLoader, obj.state == .downLoading { downloadLLM() }

        let mmprojKey = String(stringLiteral: MiniCPMModelConst.ocr_MMProjURLString).md5() ?? ""
        if let obj = info[mmprojKey] as? FDownLoader, obj.state == .downLoading { downloadMMProj() }

        let layoutKey = String(stringLiteral: MiniCPMModelConst.ocr_LayoutURLString).md5() ?? ""
        if let obj = info[layoutKey] as? FDownLoader, obj.state == .downLoading { downloadLayout() }
    }

    // MARK: - 状态查询

    func getLLMStatus() -> String    { return llmManager?.status ?? "download" }
    func getMMProjStatus() -> String { return mmprojManager?.status ?? "download" }
    func getLayoutStatus() -> String { return layoutManager?.status ?? "download" }

    func hasAnyDownloadActive() -> Bool {
        return isDownloading("ocr_llm") || isDownloading("ocr_mmproj") || isDownloading("ocr_layout")
    }

    // MARK: - 下载方法

    func downloadLLM(onComplete: (() -> Void)? = nil) {
        downloadSingle(
            manager: llmManager, modelKey: "ocr_llm",
            displayName: MiniCPMModelConst.ocr_LLMDisplayedName,
            filename: MiniCPMModelConst.ocr_LLMFileName,
            onComplete: onComplete
        )
    }

    func downloadMMProj(onComplete: (() -> Void)? = nil) {
        downloadSingle(
            manager: mmprojManager, modelKey: "ocr_mmproj",
            displayName: MiniCPMModelConst.ocr_MMProjDisplayedName,
            filename: MiniCPMModelConst.ocr_MMProjFileName,
            onComplete: onComplete
        )
    }

    func downloadLayout(onComplete: (() -> Void)? = nil) {
        downloadSingle(
            manager: layoutManager, modelKey: "ocr_layout",
            displayName: MiniCPMModelConst.ocr_LayoutDisplayedName,
            filename: MiniCPMModelConst.ocr_LayoutFileName,
            onComplete: onComplete
        )
    }

    private func downloadSingle(manager: MBModelDownloadHelperV2?, modelKey: String, displayName: String, filename: String, onComplete: (() -> Void)?) {
        guard !isDownloading(modelKey) else {
            debugLog("-->> OCR \(displayName) 正在下载中，忽略重复调用")
            return
        }
        if manager?.status == "downloaded" {
            debugLog("-->> OCR \(displayName) 已下载完成")
            onComplete?()
            return
        }

        setDownloadStatus(.downloading, for: modelKey)
        debugLog("-->> OCR \(displayName) 开始下载")
        var lastLoggedPct = -1

        manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if progress >= 1 {
                    // Post-download size validation: reject ridiculously small files
                    // (e.g. 403 error pages disguised as model files).
                    let expectedMinSize: Int64 = (modelKey == "ocr_layout") ? 50_000_000 : 100_000_000
                    let fm = FileManager.default
                    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let filePath = docs.appendingPathComponent(filename).path
                    if let attrs = try? fm.attributesOfItem(atPath: filePath),
                       let fileSize = attrs[.size] as? Int64,
                       fileSize < expectedMinSize {
                        debugLog("-->> OCR \(displayName) 文件异常小 (\(fileSize) bytes)，视为失败")
                        try? fm.removeItem(atPath: filePath)
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(displayName + L.Download.progressFailedSuffix.loc, -1)
                        self.completionHandler?(displayName, false)
                        return
                    }
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.progressHandler?(displayName, 1.0)
                    self.completionHandler?(displayName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: displayName)
                    onComplete?()
                } else if status == "failed" {
                    self.setDownloadStatus(.failed, for: modelKey)
                    self.progressHandler?(displayName + L.Download.progressFailedSuffix.loc, -1)
                    self.completionHandler?(displayName, false)
                } else {
                    let pct = Int(progress * 100)
                    if pct != lastLoggedPct, pct % 5 == 0 {
                        lastLoggedPct = pct
                    }
                    self.progressHandler?(displayName, progress)
                    self.updateDownloadProgress(progress, for: modelKey, modelName: displayName)
                }
            }
        })
    }

    // MARK: - 一键下载（串行：LLM → mmproj → layout）

    func downloadAll() {
        reconcileStatusFromDisk()
        debugLog("-->> OCR 一键下载：串行 LLM → mmproj → Layout ONNX")
        downloadLLM { [weak self] in
            self?.downloadMMProj { [weak self] in
                self?.downloadLayout()
            }
        }
    }

    func overallProgress() -> CGFloat {
        let llmBytes: Int64    = 672_139_000  // ~641 MB
        let mmprojBytes: Int64 = 931_234_000  // ~888 MB
        let layoutBytes: Int64 = 134_217_728  //  128 MB
        let total = llmBytes + mmprojBytes + layoutBytes

        let llmProg    = progress(for: "ocr_llm",    downloadedWhenDone: llmBytes)
        let mmprojProg = progress(for: "ocr_mmproj", downloadedWhenDone: mmprojBytes)
        let layoutProg = progress(for: "ocr_layout", downloadedWhenDone: layoutBytes)

        let weighted = llmProg * CGFloat(llmBytes) + mmprojProg * CGFloat(mmprojBytes) + layoutProg * CGFloat(layoutBytes)
        return total > 0 ? weighted / CGFloat(total) : 0
    }

    private func progress(for key: String, downloadedWhenDone _: Int64) -> CGFloat {
        let status = downloadQueue.sync { downloadStates[key] }
        let cached = downloadQueue.sync { downloadProgressCache[key] }
        if status == .completed { return 1.0 }
        return cached?.progress ?? 0.0
    }

    func resetDownloadStates() {
        downloadQueue.sync {
            downloadStates.removeAll()
            downloadProgressCache.removeAll()
            lastDownloadedBytes.removeAll()
        }
    }

    func deleteAllDownloadedFiles() {
        let fm = FileManager.default
        let docs = getDocumentsDirectory()
        for fname in [MiniCPMModelConst.ocr_LLMFileName,
                       MiniCPMModelConst.ocr_MMProjFileName,
                       MiniCPMModelConst.ocr_LayoutFileName] {
            let url = docs.appendingPathComponent(fname)
            try? fm.removeItem(at: url)
        }
    }

    func cleanupCacheFiles() {
        let fm = FileManager.default
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for fname in [MiniCPMModelConst.ocr_LLMFileName,
                       MiniCPMModelConst.ocr_MMProjFileName,
                       MiniCPMModelConst.ocr_LayoutFileName] {
            try? fm.removeItem(at: cache.appendingPathComponent(fname))
            try? fm.removeItem(at: tmp.appendingPathComponent(fname))
        }
    }

    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
