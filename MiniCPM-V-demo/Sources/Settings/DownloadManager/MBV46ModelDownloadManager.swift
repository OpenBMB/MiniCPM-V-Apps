//
//  MBV46ModelDownloadManager.swift
//  MiniCPM-V-demo
//
//  V4.6 instruct 下载管理器（仿 MBV4ModelDownloadManager，三段下载 + MD5 校验 + ANE zip 解压）
//

import Foundation
import UIKit
import ZipArchive

/// V4.6 模型下载管理器单例
class MBV46ModelDownloadManager: NSObject {
    
    // MARK: - 单例实现
    
    static let shared = MBV46ModelDownloadManager()
    
    private override init() {
        super.init()
    }
    
    // MARK: - 属性
    
    private var mtmdWrapperExample: MTMDWrapperExample?
    
    private var modelv46_Q4_K_M_Manager: MBModelDownloadHelperV2?
    private var mmprojv46_Manager: MBModelDownloadHelperV2?
    private var mlmodelcv46_Manager: MBModelDownloadHelperV2?
    
    var progressHandler: ((String, CGFloat) -> Void)?
    var completionHandler: ((String, Bool) -> Void)?
    var detailedProgressHandler: ((DownloadProgressInfo) -> Void)?
    
    // MARK: - 防重复调用机制
    
    private var downloadStates: [String: DownloadStatus] = [:]
    private var downloadProgressCache: [String: DownloadProgressInfo] = [:]
    private var downloadStartTimes: [String: Date] = [:]
    private var lastDownloadedBytes: [String: Int64] = [:]
    private let downloadQueue = DispatchQueue(label: "com.minicpm.v46.download", qos: .userInitiated)
    
    private func isDownloading(_ modelKey: String) -> Bool {
        return downloadQueue.sync {
            return downloadStates[modelKey] == .downloading
        }
    }
    
    private func setDownloadStatus(_ status: DownloadStatus, for modelKey: String) {
        downloadQueue.sync {
            downloadStates[modelKey] = status
            if status == .downloading {
                downloadStartTimes[modelKey] = Date()
            }
        }
    }
    
    private func updateDownloadProgress(_ progress: CGFloat, for modelKey: String, modelName: String, downloadedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        downloadQueue.sync {
            let currentTime = Date()
            let startTime = downloadStartTimes[modelKey] ?? currentTime
            let timeElapsed = currentTime.timeIntervalSince(startTime)
            
            var speed: Double = 0
            if let lastBytes = lastDownloadedBytes[modelKey], timeElapsed > 0 {
                speed = Double(downloadedBytes - lastBytes) / timeElapsed
            }
            lastDownloadedBytes[modelKey] = downloadedBytes
            
            var estimatedTimeRemaining: TimeInterval = 0
            if speed > 0 && totalBytes > downloadedBytes {
                estimatedTimeRemaining = Double(totalBytes - downloadedBytes) / speed
            }
            
            let progressInfo = DownloadProgressInfo(
                modelName: modelName,
                status: downloadStates[modelKey] ?? .notStarted,
                progress: progress,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                speed: speed,
                estimatedTimeRemaining: estimatedTimeRemaining
            )
            
            downloadProgressCache[modelKey] = progressInfo
            detailedProgressHandler?(progressInfo)
        }
    }
    
    // MARK: - 公共方法
    
    func setupDownloadManager(with wrapper: MTMDWrapperExample) {
        self.mtmdWrapperExample = wrapper
        setupModels()
    }
    
    private func setupModels() {
        guard let mtmdWrapperExample = mtmdWrapperExample else { return }
        
        modelv46_Q4_K_M_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.modelv46_FileName,
            modelUrl: MiniCPMModelConst.modelv46_Q4_K_M_URLString,
            filename: MiniCPMModelConst.modelv46_FileName,
            backupModelUrl: MiniCPMModelConst.modelv46_Q4_K_M_BackUpURLString
        )
        
        mmprojv46_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.mmprojv46_FileName,
            modelUrl: MiniCPMModelConst.mmprojv46_URLString,
            filename: MiniCPMModelConst.mmprojv46_FileName,
            backupModelUrl: MiniCPMModelConst.mmprojv46_BackUpURLString
        )
        
        mlmodelcv46_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.mlmodelcv46_ZipFileName,
            modelUrl: MiniCPMModelConst.mlmodelcv46_ZipFileURLString,
            filename: MiniCPMModelConst.mlmodelcv46_ZipFileName,
            backupModelUrl: nil
        )

        // master 适配前的老 mmproj（OBS demo-fork merger 版本）启动时直接清掉，
        // 避免 modelsExist() fast-path 拿残留文件喂给 native 加载导致闪退。
        purgeStaleArtifactsIfPresent()

        reconcileStatusFromDisk()
        restoreDownloadProgress()
    }

    /// 清理已知不兼容的历史构件（目前仅 V4.6 老 mmproj）。
    ///
    /// 单 demo 多版本演进里，"老用户机器上残留旧文件 + modelsExist() 只看存在不看 MD5"
    /// 这种情况几乎注定踩 — 把删除责任下沉到 setupModels()，跟 reconcileStatusFromDisk()
    /// 放在同一个生命周期点，比让用户去设置页删干净更稳。
    private func purgeStaleArtifactsIfPresent() {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default
        for stale in MiniCPMModelConst.staleMMProjv46_FileNames {
            let url = docs.appendingPathComponent(stale)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                debugLog("-->> 已清理老 V4.6 mmproj 残留: \(stale)")
            } catch {
                debugLog("-->> 老 V4.6 mmproj 残留清理失败: \(stale), error=\(error.localizedDescription)")
            }
        }
    }

    /// 用磁盘上的文件存在情况强制 reconcile helper.status，**完全按磁盘真相重写**。
    /// - LLM / mmproj：Documents 下对应 gguf 文件存在 → downloaded，否则 download
    /// - ANE：解压后的 .mlmodelc/.mlpackage 目录存在且非空 → downloaded；
    ///        否则一律 download（哪怕 zip 残留也不算就绪，避免误判）
    func reconcileStatusFromDisk() {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default

        let llmPath = docs.appendingPathComponent(MiniCPMModelConst.modelv46_FileName).path
        modelv46_Q4_K_M_Manager?.status = fm.fileExists(atPath: llmPath) ? "downloaded" : "download"

        let mmprojPath = docs.appendingPathComponent(MiniCPMModelConst.mmprojv46_FileName).path
        mmprojv46_Manager?.status = fm.fileExists(atPath: mmprojPath) ? "downloaded" : "download"

        mlmodelcv46_Manager?.status = isMLModelcReady() ? "downloaded" : "download"
    }

    /// ANE 模型是否真的就绪：解压后的 mlmodelc/mlpackage 目录存在且非空
    /// 注意：仅 zip 残留不算就绪 —— ANE 实际加载用的是解压后的目录
    private func isMLModelcReady() -> Bool {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default
        for name in MiniCPMModelConst.mlmodelcv46_CandidateFileNames {
            let dirURL = docs.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let contents = try? fm.contentsOfDirectory(atPath: dirURL.path), !contents.isEmpty {
                return true
            }
        }
        return false
    }
    
    private func restoreDownloadProgress() {
        guard let info = FDownLoaderManager.shareInstance().downLoaderInfo else { return }
        
        let llmKey = String(stringLiteral: MiniCPMModelConst.modelv46_Q4_K_M_URLString).md5() ?? ""
        if let obj = info[llmKey] as? FDownLoader, obj.state == .downLoading {
            downloadModelv46_Q4_K_M()
        }
        
        let mmprojKey = String(stringLiteral: MiniCPMModelConst.mmprojv46_URLString).md5() ?? ""
        if let obj = info[mmprojKey] as? FDownLoader, obj.state == .downLoading {
            downloadMMProjv46()
        }
        
        let aneKey = String(stringLiteral: MiniCPMModelConst.mlmodelcv46_ZipFileURLString).md5() ?? ""
        if let obj = info[aneKey] as? FDownLoader, obj.state == .downLoading {
            downloadMLModelcv46()
        }
    }
    
    // MARK: - 下载方法
    
    func downloadModelv46_Q4_K_M() {
        let modelKey = "v46_main_model"
        
        guard !isDownloading(modelKey) else {
            debugLog("-->> V4.6 主模型正在下载中，忽略重复调用")
            return
        }
        if getModelv46_Q4_K_M_Status() == "downloaded" {
            debugLog("-->> V4.6 主模型已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        modelv46_Q4_K_M_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyModelv46_Q4_K_M_MD5()
                    self.progressHandler?(MiniCPMModelConst.modelv46_DisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.modelv46_DisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.modelv46_DisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.modelv46_DisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.modelv46_DisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.modelv46_DisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.modelv46_DisplayedName)
                    }
                }
            }
        })
    }
    
    func downloadMMProjv46() {
        let modelKey = "v46_mmproj_model"
        
        guard !isDownloading(modelKey) else {
            debugLog("-->> V4.6 VIT 模型正在下载中，忽略重复调用")
            return
        }
        if getMMProjv46_Status() == "downloaded" {
            debugLog("-->> V4.6 VIT 模型已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        mmprojv46_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyMMProjv46_MD5()
                    self.progressHandler?(MiniCPMModelConst.modelMMProjv46_DisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.modelMMProjv46_DisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.modelMMProjv46_DisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.modelMMProjv46_DisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.modelMMProjv46_DisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.modelMMProjv46_DisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.modelMMProjv46_DisplayedName)
                    }
                }
            }
        })
    }
    
    func downloadMLModelcv46() {
        let modelKey = "v46_ane_module"
        
        guard !isDownloading(modelKey) else {
            debugLog("-->> V4.6 ANE 模块正在下载中，忽略重复调用")
            return
        }
        if getMLModelcv46_Status() == "downloaded" {
            debugLog("-->> V4.6 ANE 模块已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        mlmodelcv46_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyAndExtractMLModelcv46()
                    self.progressHandler?(MiniCPMModelConst.mlmodelcv46_DisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.mlmodelcv46_DisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.mlmodelcv46_DisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.mlmodelcv46_DisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.mlmodelcv46_DisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.mlmodelcv46_DisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.mlmodelcv46_DisplayedName)
                    }
                }
            }
        })
    }
    
    // MARK: - 一键下载

    /// 一键下载：默认只拉 LLM + VPM 两段。
    /// ANE/CoreML 包当前默认禁用（mtmd_coreml.mm 已切到 MLComputeUnitsCPUAndGPU，
    /// 走 Metal 不走 ANE；ggml/Metal 路径可独立完成 ViT+merger）。
    /// 想恢复时取消注释 `downloadMLModelcv46()` 即可。
    func downloadAll() {
        reconcileStatusFromDisk()
        debugLog("-->> V4.6 一键下载：同时拉起 LLM + VPM（ANE 已默认禁用）")
        downloadModelv46_Q4_K_M()
        downloadMMProjv46()
        // downloadMLModelcv46()  // ANE 暂禁用，恢复时取消注释
    }

    /// 综合进度（按预估字节加权），0..1。ANE 当前不参与下载，故不计入进度。
    func overallProgress() -> CGFloat {
        // 预估字节数（与服务器 Content-Length 一致）
        let llmBytes: Int64    = 529_100_256
        let mmprojBytes: Int64 = 1_097_457_216
        // let aneBytes: Int64 = 1_030_316_868  // ANE 暂禁用，恢复时取消注释并加回 total / weighted
        let total = llmBytes + mmprojBytes

        let llmProg    = progress(for: "v46_main_model",  downloadedWhenDone: llmBytes)
        let mmprojProg = progress(for: "v46_mmproj_model", downloadedWhenDone: mmprojBytes)
        // let aneProg = progress(for: "v46_ane_module", downloadedWhenDone: aneBytes)

        let weighted = llmProg * CGFloat(llmBytes)
                     + mmprojProg * CGFloat(mmprojBytes)
                     // + aneProg * CGFloat(aneBytes)
        return weighted / CGFloat(total)
    }

    private func progress(for modelKey: String, downloadedWhenDone: Int64) -> CGFloat {
        let status: String
        switch modelKey {
        case "v46_main_model":   status = getModelv46_Q4_K_M_Status()
        case "v46_mmproj_model": status = getMMProjv46_Status()
        case "v46_ane_module":   status = getMLModelcv46_Status()
        default: status = "download"
        }
        if status == "downloaded" { return 1.0 }
        if let info = downloadQueue.sync(execute: { downloadProgressCache[modelKey] }) {
            return info.progress
        }
        return 0
    }

    // MARK: - 进度查询
    
    func getDownloadProgress(for modelKey: String) -> DownloadProgressInfo? {
        return downloadQueue.sync { downloadProgressCache[modelKey] }
    }
    
    func getAllDownloadProgress() -> [String: DownloadProgressInfo] {
        return downloadQueue.sync { downloadProgressCache }
    }
    
    func getDownloadStatus(for modelKey: String) -> DownloadStatus {
        return downloadQueue.sync { downloadStates[modelKey] ?? .notStarted }
    }
    
    func getAllDownloadStatus() -> [String: DownloadStatus] {
        return downloadQueue.sync { downloadStates }
    }
    
    // MARK: - MD5 校验
    
    private func verifyModelv46_Q4_K_M_MD5() {
        let fileURL = getDocumentsDirectory().appendingPathComponent(MiniCPMModelConst.modelv46_FileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // MD5 一个 0.5 GiB 文件在 iPhone 上要好几秒，过去这段直接跑在 main 上
        // 触发了用户感受到的"下载完成那一刻 UI 卡死"。挪到 userInitiated background
        // 队列算，算完再回 main 改 status / 触发 deleteAction —— 后续 UI 操作仍在
        // main，但不阻塞用户后续点按钮。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checksum = MBUtils.md5(for: fileURL)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let checksum = checksum {
                    debugLog("-->> V4.6 主模型 实际 MD5: \(checksum)")
                    debugLog("-->> V4.6 主模型 期望 MD5: \(MiniCPMModelConst.modelv46_Q4_K_M_MD5)")
                    if checksum == MiniCPMModelConst.modelv46_Q4_K_M_MD5 {
                        debugLog("-->> V4.6 主模型 MD5 校验成功")
                        self.modelv46_Q4_K_M_Manager?.status = "downloaded"
                        self.setDownloadStatus(.completed, for: "v46_main_model")
                    } else {
                        debugLog("-->> V4.6 主模型 MD5 校验失败")
                        self.modelv46_Q4_K_M_Manager?.status = "download"
                        self.deleteModelv46_Q4_K_M()
                    }
                } else {
                    debugLog("-->> V4.6 主模型 MD5 计算失败")
                    self.modelv46_Q4_K_M_Manager?.status = "download"
                    self.deleteModelv46_Q4_K_M()
                }
            }
        }
    }

    private func verifyMMProjv46_MD5() {
        let fileURL = getDocumentsDirectory().appendingPathComponent(MiniCPMModelConst.mmprojv46_FileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // MD5 1.1 GiB mmproj 在 iPhone 上 4-8 秒（之前 main 卡死的元凶）。同上策略。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checksum = MBUtils.md5(for: fileURL)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let checksum = checksum {
                    debugLog("-->> V4.6 VIT 模型 实际 MD5: \(checksum)")
                    debugLog("-->> V4.6 VIT 模型 期望 MD5: \(MiniCPMModelConst.modelMMProjv46_MD5)")
                    if checksum == MiniCPMModelConst.modelMMProjv46_MD5 {
                        debugLog("-->> V4.6 VIT 模型 MD5 校验成功")
                        self.mmprojv46_Manager?.status = "downloaded"
                        self.setDownloadStatus(.completed, for: "v46_mmproj_model")
                    } else {
                        debugLog("-->> V4.6 VIT 模型 MD5 校验失败")
                        self.mmprojv46_Manager?.status = "download"
                        self.deleteMMProjv46()
                    }
                } else {
                    debugLog("-->> V4.6 VIT 模型 MD5 计算失败")
                    self.mmprojv46_Manager?.status = "download"
                    self.deleteMMProjv46()
                }
            }
        }
    }
    
    private func verifyAndExtractMLModelcv46() {
        let fileURL = getDocumentsDirectory().appendingPathComponent(MiniCPMModelConst.mlmodelcv46_ZipFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // MD5 + zip 解压 1+ GiB 全在 background 跑，跟 verifyModelv46_Q4_K_M_MD5 同款策略。
        // SSZipArchive.unzipFile 解 1 GB 包大约 5-15 s，绝对不能在 main 跑。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?._verifyAndExtractMLModelcv46_offMain(fileURL: fileURL)
        }
    }

    private func _verifyAndExtractMLModelcv46_offMain(fileURL: URL) {
        guard let checksum = MBUtils.md5(for: fileURL) else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V4.6 ANE 模块 MD5 计算失败")
                self?.mlmodelcv46_Manager?.status = "download"
                self?.deleteMLModelcv46()
            }
            return
        }

        debugLog("-->> V4.6 ANE 模块 实际 MD5: \(checksum)")
        debugLog("-->> V4.6 ANE 模块 期望 MD5: \(MiniCPMModelConst.mlmodelcv46_ZipFileMD5)")

        guard checksum == MiniCPMModelConst.mlmodelcv46_ZipFileMD5 else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V4.6 ANE 模块 MD5 校验失败")
                self?.mlmodelcv46_Manager?.status = "download"
                self?.deleteMLModelcv46()
            }
            return
        }

        let destPath = getDocumentsDirectory().path
        var error: NSError?
        SSZipArchive.unzipFile(
            atPath: fileURL.path,
            toDestination: destPath,
            preserveAttributes: true,
            overwrite: true,
            password: nil,
            error: &error,
            delegate: nil
        )
        
        if let error = error {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V4.6 ANE 模块解压失败: \(error.localizedDescription)")
                self?.mlmodelcv46_Manager?.status = "download"
                self?.deleteMLModelcv46()
            }
            return
        }

        guard isMLModelcReady() else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V4.6 ANE 模块解压后目录为空或缺失，视为失败")
                self?.mlmodelcv46_Manager?.status = "download"
                self?.deleteMLModelcv46()
            }
            return
        }

        // zip 删除属于 disk IO，留在 background 跑完，UI 只关心最终的 status。
        do {
            try FileManager.default.removeItem(at: fileURL)
            debugLog("-->> V4.6 ANE 模块 zip 已删除（解压后不再需要）")
        } catch {
            debugLog("-->> V4.6 ANE 模块 zip 删除失败: \(error.localizedDescription)")
        }

        DispatchQueue.main.async { [weak self] in
            debugLog("-->> V4.6 ANE 模块解压成功")
            self?.mlmodelcv46_Manager?.status = "downloaded"
            self?.setDownloadStatus(.completed, for: "v46_ane_module")
        }
    }
    
    // MARK: - 删除方法
    
    func deleteModelv46_Q4_K_M() {
        let fileURL = getDocumentsDirectory().appendingPathComponent(MiniCPMModelConst.modelv46_FileName)
        do {
            try FileManager.default.removeItem(at: fileURL)
            modelv46_Q4_K_M_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v46_main_model")
            debugLog("-->> V4.6 主模型删除成功")
        } catch {
            debugLog("-->> V4.6 主模型删除失败: \(error.localizedDescription)")
        }
    }
    
    func deleteMMProjv46() {
        let fileURL = getDocumentsDirectory().appendingPathComponent(MiniCPMModelConst.mmprojv46_FileName)
        do {
            try FileManager.default.removeItem(at: fileURL)
            mmprojv46_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v46_mmproj_model")
            debugLog("-->> V4.6 VIT 模型删除成功")
        } catch {
            debugLog("-->> V4.6 VIT 模型删除失败: \(error.localizedDescription)")
        }
    }
    
    func deleteMLModelcv46() {
        let fileURL = getDocumentsDirectory().appendingPathComponent(MiniCPMModelConst.mlmodelcv46_ZipFileName)
        do {
            try FileManager.default.removeItem(at: fileURL)
            mlmodelcv46_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v46_ane_module")
            debugLog("-->> V4.6 ANE 模块 zip 删除成功")
        } catch {
            debugLog("-->> V4.6 ANE 模块 zip 删除失败: \(error.localizedDescription)")
        }
        // 同时尝试删除已解压的 mlmodelc 目录
        for candidate in MiniCPMModelConst.mlmodelcv46_CandidateFileNames {
            let dirURL = getDocumentsDirectory().appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: dirURL.path) {
                try? FileManager.default.removeItem(at: dirURL)
            }
        }
    }
    
    // MARK: - 状态查询
    
    func getModelv46_Q4_K_M_Status() -> String {
        return modelv46_Q4_K_M_Manager?.status ?? "download"
    }
    
    func getMMProjv46_Status() -> String {
        return mmprojv46_Manager?.status ?? "download"
    }
    
    func getMLModelcv46_Status() -> String {
        return mlmodelcv46_Manager?.status ?? "download"
    }
    
    func hasAnyModelDownloading() -> Bool {
        return downloadQueue.sync { downloadStates.values.contains(.downloading) }
    }

    /// 比 hasAnyModelDownloading 更可靠：先按磁盘 reconcile，再判断"还有未完成的下载任务"。
    /// 已经在磁盘上落地的 key 即使 downloadStates 里残留 .downloading 也会被忽略，
    /// 解决"全部下载完成但 helper.status 没及时切到 downloaded，按钮卡在下载中 100%"。
    func hasAnyDownloadActive() -> Bool {
        reconcileStatusFromDisk()

        let mainDone = (modelv46_Q4_K_M_Manager?.status == "downloaded")
        let mmprojDone = (mmprojv46_Manager?.status == "downloaded")
        let aneDone = (mlmodelcv46_Manager?.status == "downloaded")

        return downloadQueue.sync {
            for (key, state) in downloadStates {
                guard state == .downloading || state == .paused else { continue }
                switch key {
                case "v46_main_model":   if mainDone   { continue }
                case "v46_mmproj_model": if mmprojDone { continue }
                case "v46_ane_module":   if aneDone    { continue }
                default: break
                }
                return true
            }
            return false
        }
    }
    
    // MARK: - 工具方法
    
    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func pauseAllDownloads() {
        FDownLoaderManager.shareInstance().pauseAll()
        downloadQueue.sync {
            for key in downloadStates.keys where downloadStates[key] == .downloading {
                downloadStates[key] = .paused
            }
        }
    }
    
    func resumeAllDownloads() {
        FDownLoaderManager.shareInstance().resumeAll()
        downloadQueue.sync {
            for key in downloadStates.keys where downloadStates[key] == .paused {
                downloadStates[key] = .downloading
            }
        }
    }
    
    func cancelAllDownloads() {
        FDownLoaderManager.shareInstance().downLoaderInfo.removeAllObjects()
        downloadQueue.sync {
            downloadStates.removeAll()
            downloadProgressCache.removeAll()
            downloadStartTimes.removeAll()
            lastDownloadedBytes.removeAll()
        }
    }
    
    func resetDownloadStates() {
        downloadQueue.sync {
            downloadStates.removeAll()
            downloadProgressCache.removeAll()
            downloadStartTimes.removeAll()
            lastDownloadedBytes.removeAll()
        }
    }
    
    // MARK: - 公共访问
    
    var mainModelManager: MBModelDownloadHelperV2? { modelv46_Q4_K_M_Manager }
    var vitModelManager: MBModelDownloadHelperV2? { mmprojv46_Manager }
    var aneModelManager: MBModelDownloadHelperV2? { mlmodelcv46_Manager }
}
