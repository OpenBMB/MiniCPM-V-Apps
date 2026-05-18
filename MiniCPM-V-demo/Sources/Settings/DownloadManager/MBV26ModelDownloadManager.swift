//
//  MBV26ModelDownloadManager.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 12/7/2025.
//

import Foundation
import UIKit
import ZipArchive

/// 下载状态枚举
enum V26DownloadStatus {
    case notStarted
    case downloading
    case paused
    case completed
    case failed
}

/// 下载进度信息结构
struct V26DownloadProgressInfo {
    let modelName: String
    let status: V26DownloadStatus
    let progress: CGFloat
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speed: Double // bytes per second
    let estimatedTimeRemaining: TimeInterval
}

/// V26 模型下载管理器单例
class MBV26ModelDownloadManager: NSObject {
    
    // MARK: - 单例实现
    
    static let shared = MBV26ModelDownloadManager()
    
    private override init() {
        super.init()
    }
    
    // MARK: - 属性
    
    /// 外部传入的 llamaState 引用
    private var mtmdWrapperExample: MTMDWrapperExample?
    
    /// V26 主模型下载管理器
    private var modelV26_Q4_K_M_Manager: MBModelDownloadHelperV2?
    
    /// V26 mmproj VIT 模型下载管理器
    private var mmprojV26_Manager: MBModelDownloadHelperV2?
    
    /// V26 ANE 模块下载管理器
    private var mlmodelcV26_Manager: MBModelDownloadHelperV2?
    
    /// 下载进度回调
    var progressHandler: ((String, CGFloat) -> Void)?
    
    /// 下载完成回调
    var completionHandler: ((String, Bool) -> Void)?
    
    /// 详细进度信息回调
    var detailedProgressHandler: ((V26DownloadProgressInfo) -> Void)?
    
    // MARK: - 防重复调用机制
    
    /// 下载状态跟踪
    private var downloadStates: [String: V26DownloadStatus] = [:]
    
    /// 下载进度缓存
    private var downloadProgressCache: [String: V26DownloadProgressInfo] = [:]
    
    /// 下载开始时间记录
    private var downloadStartTimes: [String: Date] = [:]
    
    /// 上次下载字节数记录（用于计算速度）
    private var lastDownloadedBytes: [String: Int64] = [:]
    
    /// 防重复调用锁
    private let downloadQueue = DispatchQueue(label: "com.minicpm.v26.download", qos: .userInitiated)
    
    /// 检查是否正在下载指定模型
    private func isDownloading(_ modelKey: String) -> Bool {
        return downloadQueue.sync {
            return downloadStates[modelKey] == .downloading
        }
    }
    
    /// 设置下载状态
    private func setDownloadStatus(_ status: V26DownloadStatus, for modelKey: String) {
        downloadQueue.sync {
            downloadStates[modelKey] = status
            if status == .downloading {
                downloadStartTimes[modelKey] = Date()
            }
        }
    }
    
    /// 更新下载进度
    private func updateDownloadProgress(_ progress: CGFloat, for modelKey: String, modelName: String, downloadedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        downloadQueue.sync {
            let currentTime = Date()
            let startTime = downloadStartTimes[modelKey] ?? currentTime
            let timeElapsed = currentTime.timeIntervalSince(startTime)
            
            // 计算下载速度
            var speed: Double = 0
            if let lastBytes = lastDownloadedBytes[modelKey], timeElapsed > 0 {
                speed = Double(downloadedBytes - lastBytes) / timeElapsed
            }
            lastDownloadedBytes[modelKey] = downloadedBytes
            
            // 计算剩余时间
            var estimatedTimeRemaining: TimeInterval = 0
            if speed > 0 && totalBytes > downloadedBytes {
                estimatedTimeRemaining = Double(totalBytes - downloadedBytes) / speed
            }
            
            let progressInfo = V26DownloadProgressInfo(
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
    
    /// 初始化下载管理器
    /// - Parameter wrapper: llama mtmd wrapper 状态管理器
    func setupDownloadManager(with wrapper: MTMDWrapperExample) {
        self.mtmdWrapperExample = wrapper
        setupModels()
    }
    
    /// 配置所有V26模型
    private func setupModels() {
        guard let mtmdWrapperExample = mtmdWrapperExample else { return }
        
        // V26 主模型
        let modelV26_Q4_K_M_URLString = MiniCPMModelConst.modelQ4_K_MURLString
        modelV26_Q4_K_M_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.modelQ4_K_MFileName,
            modelUrl: modelV26_Q4_K_M_URLString,
            filename: MiniCPMModelConst.modelQ4_K_MFileName
        )
        
        // V26 mmproj VIT 模型
        let mmprojV26_URLString = MiniCPMModelConst.mmprojURLString
        mmprojV26_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.mmprojFileName,
            modelUrl: mmprojV26_URLString,
            filename: MiniCPMModelConst.mmprojFileName
        )
        
        // V26 ANE 模块
        let mlmodelcV26_URLString = MiniCPMModelConst.mlmodelcZipFileURLString
        mlmodelcV26_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.mlmodelcZipFileName,
            modelUrl: mlmodelcV26_URLString,
            filename: MiniCPMModelConst.mlmodelcZipFileName
        )
        
        // 恢复断点续传
        restoreDownloadProgress()
    }
    
    /// 恢复下载进度
    private func restoreDownloadProgress() {
        guard let info = FDownLoaderManager.shareInstance().downLoaderInfo else { return }
        
        // 恢复 V26 主模型下载进度
        let modelV26_Q4_K_M_FileName = String(stringLiteral: MiniCPMModelConst.modelQ4_K_MURLString).md5() ?? ""
        if let obj = info[modelV26_Q4_K_M_FileName] as? FDownLoader {
            if obj.state == .downLoading {
                downloadModelV26_Q4_K_M()
            }
        }
        
        // 恢复 V26 mmproj 模型下载进度
        let mmprojV26_FileName = String(stringLiteral: MiniCPMModelConst.mmprojURLString).md5() ?? ""
        if let obj = info[mmprojV26_FileName] as? FDownLoader {
            if obj.state == .downLoading {
                downloadMMProjV26()
            }
        }
        
        // 恢复 V26 ANE 模块下载进度
        let mlmodelcV26_FileName = String(stringLiteral: MiniCPMModelConst.mlmodelcZipFileURLString).md5() ?? ""
        if let obj = info[mlmodelcV26_FileName] as? FDownLoader {
            if obj.state == .downLoading {
                downloadMLModelcV26()
            }
        }
    }

    // MARK: - reconcile / readiness（V4.6 / V4 同款）

    /// 用磁盘上的文件存在情况强制 reconcile helper.status，**完全按磁盘真相重写**。
    /// - LLM / mmproj：Documents 下对应 gguf 存在 → downloaded，否则 download
    /// - ANE：解压后的 .mlmodelc/.mlpackage 目录存在且非空 → downloaded；
    ///        否则一律 download（zip 残留不算就绪）
    func reconcileStatusFromDisk() {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default

        let llmPath = docs.appendingPathComponent(MiniCPMModelConst.modelQ4_K_MFileName).path
        modelV26_Q4_K_M_Manager?.status = fm.fileExists(atPath: llmPath) ? "downloaded" : "download"

        let mmprojPath = docs.appendingPathComponent(MiniCPMModelConst.mmprojFileName).path
        mmprojV26_Manager?.status = fm.fileExists(atPath: mmprojPath) ? "downloaded" : "download"

        mlmodelcV26_Manager?.status = isMLModelcV26Ready() ? "downloaded" : "download"
    }

    /// V26 ANE 解压后目录是否就绪
    private func isMLModelcV26Ready() -> Bool {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default
        let stem = (MiniCPMModelConst.mlmodelcZipFileName as NSString).deletingPathExtension
        let candidates = [stem, (stem as NSString).deletingPathExtension + ".mlpackage"]
        for name in candidates {
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

    // MARK: - 一键下载

    /// 一键下载：默认只拉 LLM + VPM 两段（ANE/CoreML 包默认禁用，参见 MBV26ModelDetailViewController 注释）。
    func downloadAll() {
        reconcileStatusFromDisk()
        debugLog("-->> V2.6 一键下载：同时拉起 LLM + VPM（ANE 已默认禁用）")
        downloadModelV26_Q4_K_M()
        downloadMMProjV26()
        // downloadMLModelcV26()  // ANE 暂禁用，恢复时取消注释
    }

    /// 综合进度，0..1。ANE 当前不参与，故不计入。
    func overallProgress() -> CGFloat {
        let mainProg   = progress(forKey: "v26_main_model")
        let mmprojProg = progress(forKey: "v26_mmproj_model")
        // let aneProg = progress(forKey: "v26_ane_module")  // ANE 暂禁用
        return (mainProg + mmprojProg) / 2.0
    }

    private func progress(forKey modelKey: String) -> CGFloat {
        let status: String
        switch modelKey {
        case "v26_main_model":   status = getModelV26_Q4_K_M_Status()
        case "v26_mmproj_model": status = getMMProjV26_Status()
        case "v26_ane_module":   status = getMLModelcV26_Status()
        default: status = "download"
        }
        if status == "downloaded" { return 1.0 }
        if let info = downloadQueue.sync(execute: { downloadProgressCache[modelKey] }) {
            return info.progress
        }
        return 0
    }

    /// 比 hasAnyModelDownloading 更可靠：先 reconcile，再判断"还有未完成的下载任务"。
    /// 已经在磁盘上落地的 key 即使 downloadStates 残留 .downloading 也会被忽略。
    func hasAnyDownloadActive() -> Bool {
        reconcileStatusFromDisk()

        let mainDone = (modelV26_Q4_K_M_Manager?.status == "downloaded")
        let mmprojDone = (mmprojV26_Manager?.status == "downloaded")
        let aneDone = (mlmodelcV26_Manager?.status == "downloaded")

        return downloadQueue.sync {
            for (key, state) in downloadStates {
                guard state == .downloading || state == .paused else { continue }
                switch key {
                case "v26_main_model":   if mainDone   { continue }
                case "v26_mmproj_model": if mmprojDone { continue }
                case "v26_ane_module":   if aneDone    { continue }
                default: break
                }
                return true
            }
            return false
        }
    }

    // MARK: - 下载方法（带防重复调用）
    
    /// 下载 V26 主模型
    func downloadModelV26_Q4_K_M() {
        let modelKey = "v26_main_model"
        
        // 防重复调用检查
        guard !isDownloading(modelKey) else {
            debugLog("-->> V26主模型正在下载中，忽略重复调用")
            return
        }
        
        // 检查是否已下载
        if getModelV26_Q4_K_M_Status() == "downloaded" {
            debugLog("-->> V26主模型已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        modelV26_Q4_K_M_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    // 下载完成，进行MD5校验
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyModelV26_Q4_K_M_MD5()
                    self.progressHandler?(MiniCPMModelConst.modelQ4_K_MDisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.modelQ4_K_MDisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.modelQ4_K_MDisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.modelQ4_K_MDisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.modelQ4_K_MDisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.modelQ4_K_MDisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.modelQ4_K_MDisplayedName)
                    }
                }
            }
        })
    }
    
    /// 下载 V26 mmproj VIT 模型
    func downloadMMProjV26() {
        let modelKey = "v26_mmproj_model"
        
        // 防重复调用检查
        guard !isDownloading(modelKey) else {
            debugLog("-->> V26 VIT模型正在下载中，忽略重复调用")
            return
        }
        
        // 检查是否已下载
        if getMMProjV26_Status() == "downloaded" {
            debugLog("-->> V26 VIT模型已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        mmprojV26_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    // 下载完成，进行MD5校验
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyMMProjV26_MD5()
                    self.progressHandler?(MiniCPMModelConst.modelMMProjDisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.modelMMProjDisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.modelMMProjDisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.modelMMProjDisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.modelMMProjDisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.modelMMProjDisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.modelMMProjDisplayedName)
                    }
                }
            }
        })
    }
    
    /// 下载 V26 ANE 模块
    func downloadMLModelcV26() {
        let modelKey = "v26_ane_module"
        
        // 防重复调用检查
        guard !isDownloading(modelKey) else {
            debugLog("-->> V26 ANE模块正在下载中，忽略重复调用")
            return
        }
        
        // 检查是否已下载
        if getMLModelcV26_Status() == "downloaded" {
            debugLog("-->> V26 ANE模块已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        mlmodelcV26_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    // 下载完成，进行MD5校验和解压缩
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyAndExtractMLModelcV26()
                    self.progressHandler?(MiniCPMModelConst.mlmodelcZipFileDisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.mlmodelcZipFileDisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.mlmodelcZipFileDisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.mlmodelcZipFileDisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.mlmodelcZipFileDisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.mlmodelcZipFileDisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.mlmodelcZipFileDisplayedName)
                    }
                }
            }
        })
    }
    
    // MARK: - 下载进度查看方法
    
    /// 获取指定模型的下载进度信息
    /// - Parameter modelKey: 模型标识符
    /// - Returns: 下载进度信息
    func getDownloadProgress(for modelKey: String) -> V26DownloadProgressInfo? {
        return downloadQueue.sync {
            return downloadProgressCache[modelKey]
        }
    }
    
    /// 获取所有模型的下载进度信息
    /// - Returns: 所有模型的下载进度信息字典
    func getAllDownloadProgress() -> [String: V26DownloadProgressInfo] {
        return downloadQueue.sync {
            return downloadProgressCache
        }
    }
    
    /// 获取指定模型的下载状态
    /// - Parameter modelKey: 模型标识符
    /// - Returns: 下载状态
    func getDownloadStatus(for modelKey: String) -> V26DownloadStatus {
        return downloadQueue.sync {
            return downloadStates[modelKey] ?? .notStarted
        }
    }
    
    /// 获取所有模型的下载状态
    /// - Returns: 所有模型的下载状态字典
    func getAllDownloadStatus() -> [String: V26DownloadStatus] {
        return downloadQueue.sync {
            return downloadStates
        }
    }
    
    /// 格式化下载速度显示
    /// - Parameter bytesPerSecond: 每秒字节数
    /// - Returns: 格式化的速度字符串
    func formatDownloadSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
    
    /// 格式化剩余时间显示
    /// - Parameter timeInterval: 时间间隔（秒）
    /// - Returns: 格式化的时间字符串
    func formatTimeRemaining(_ timeInterval: TimeInterval) -> String {
        if timeInterval.isInfinite || timeInterval.isNaN || timeInterval <= 0 {
            return "计算中..."
        }
        
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) % 3600 / 60
        let seconds = Int(timeInterval) % 60
        
        if hours > 0 {
            return String(format: "%d小时%d分钟", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%d分钟%d秒", minutes, seconds)
        } else {
            return String(format: "%d秒", seconds)
        }
    }
    
    /// 获取文件大小显示
    /// - Parameter bytes: 字节数
    /// - Returns: 格式化的文件大小字符串
    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - MD5 校验方法
    
    /// 校验 V26 主模型 MD5（off-main，详见 V46 同款 verify 注释）
    private func verifyModelV26_Q4_K_M_MD5() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.modelQ4_K_MFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checksum = MBUtils.md5(for: fileURL)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let checksum = checksum {
                    debugLog("-->> V26主模型 实际MD5值: \(checksum)")
                    debugLog("-->> V26主模型 期望MD5值: \(MiniCPMModelConst.modelQ4_K_MMD5)")
                    if checksum == MiniCPMModelConst.modelQ4_K_MMD5 {
                        debugLog("-->> V26主模型 MD5校验成功: \(checksum)")
                        self.modelV26_Q4_K_M_Manager?.status = "downloaded"
                    } else {
                        debugLog("-->> V26主模型 MD5校验失败")
                        self.modelV26_Q4_K_M_Manager?.status = "download"
                        self.deleteModelV26_Q4_K_M()
                    }
                } else {
                    debugLog("-->> V26主模型 MD5计算失败")
                    self.modelV26_Q4_K_M_Manager?.status = "download"
                    self.deleteModelV26_Q4_K_M()
                }
            }
        }
    }

    /// 校验 V26 mmproj 模型 MD5（off-main）
    private func verifyMMProjV26_MD5() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mmprojFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checksum = MBUtils.md5(for: fileURL)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let checksum = checksum {
                    debugLog("-->> V26 VIT模型 实际MD5值: \(checksum)")
                    debugLog("-->> V26 VIT模型 期望MD5值: \(MiniCPMModelConst.modelMMProjMD5)")
                    if checksum == MiniCPMModelConst.modelMMProjMD5 {
                        debugLog("-->> V26 VIT模型 MD5校验成功: \(checksum)")
                        self.mmprojV26_Manager?.status = "downloaded"
                    } else {
                        debugLog("-->> V26 VIT模型 MD5校验失败")
                        self.mmprojV26_Manager?.status = "download"
                        self.deleteMMProjV26()
                    }
                } else {
                    debugLog("-->> V26 VIT模型 MD5计算失败")
                    self.mmprojV26_Manager?.status = "download"
                    self.deleteMMProjV26()
                }
            }
        }
    }

    /// 校验并解压 V26 ANE 模块（off-main：MD5 + zip 解压都在 background 跑）
    private func verifyAndExtractMLModelcV26() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mlmodelcZipFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?._verifyAndExtractMLModelcV26_offMain(fileURL: fileURL)
        }
    }

    private func _verifyAndExtractMLModelcV26_offMain(fileURL: URL) {
        guard let checksum = MBUtils.md5(for: fileURL) else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V26 ANE模块 MD5计算失败")
                self?.mlmodelcV26_Manager?.status = "download"
                self?.deleteMLModelcV26()
            }
            return
        }

        debugLog("-->> V26 ANE模块 实际MD5值: \(checksum)")
        debugLog("-->> V26 ANE模块 期望MD5值: \(MiniCPMModelConst.mlmodelcZipFileMD5)")

        guard checksum == MiniCPMModelConst.mlmodelcZipFileMD5 else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V26 ANE模块 MD5校验失败")
                self?.mlmodelcV26_Manager?.status = "download"
                self?.deleteMLModelcV26()
            }
            return
        }

        let destPath = getDocumentsDirectory().path
        guard !destPath.isEmpty else { return }

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
                debugLog("-->> V26 ANE模块解压失败: \(error.localizedDescription)")
                self?.mlmodelcV26_Manager?.status = "download"
                self?.deleteMLModelcV26()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V26 ANE模块解压成功")
                self?.mlmodelcV26_Manager?.status = "downloaded"
            }
        }
    }
    
    // MARK: - 删除方法
    
    /// 删除 V26 主模型
    func deleteModelV26_Q4_K_M() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.modelQ4_K_MFileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            modelV26_Q4_K_M_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v26_main_model")
            debugLog("-->> V26主模型删除成功")
        } catch {
            debugLog("-->> V26主模型删除失败: \(error.localizedDescription)")
        }
    }
    
    /// 删除 V26 mmproj 模型
    func deleteMMProjV26() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mmprojFileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            mmprojV26_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v26_mmproj_model")
            debugLog("-->> V26 VIT模型删除成功")
        } catch {
            debugLog("-->> V26 VIT模型删除失败: \(error.localizedDescription)")
        }
    }
    
    /// 删除 V26 ANE 模块
    func deleteMLModelcV26() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mlmodelcZipFileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            mlmodelcV26_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v26_ane_module")
            debugLog("-->> V26 ANE模块删除成功")
        } catch {
            debugLog("-->> V26 ANE模块删除失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 状态查询方法
    
    /// 获取 V26 主模型状态
    func getModelV26_Q4_K_M_Status() -> String {
        return modelV26_Q4_K_M_Manager?.status ?? "download"
    }
    
    /// 获取 V26 mmproj 模型状态
    func getMMProjV26_Status() -> String {
        return mmprojV26_Manager?.status ?? "download"
    }
    
    /// 获取 V26 ANE 模块状态
    func getMLModelcV26_Status() -> String {
        return mlmodelcV26_Manager?.status ?? "download"
    }
    
    /// 检查是否有正在进行的下载任务
    func hasActiveDownloads() -> Bool {
        guard let info = FDownLoaderManager.shareInstance().downLoaderInfo else { return false }
        return !info.allKeys.isEmpty
    }
    
    /// 检查是否有任何模型正在下载
    func hasAnyModelDownloading() -> Bool {
        return downloadQueue.sync {
            return downloadStates.values.contains(.downloading)
        }
    }
    
    // MARK: - 工具方法
    
    /// 获取 Documents 目录
    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// 暂停所有下载
    func pauseAllDownloads() {
        FDownLoaderManager.shareInstance().pauseAll()
        downloadQueue.sync {
            for key in downloadStates.keys {
                if downloadStates[key] == .downloading {
                    downloadStates[key] = .paused
                }
            }
        }
    }
    
    /// 恢复所有下载
    func resumeAllDownloads() {
        FDownLoaderManager.shareInstance().resumeAll()
        downloadQueue.sync {
            for key in downloadStates.keys {
                if downloadStates[key] == .paused {
                    downloadStates[key] = .downloading
                }
            }
        }
    }
    
    /// 取消所有下载
    func cancelAllDownloads() {
        FDownLoaderManager.shareInstance().downLoaderInfo.removeAllObjects()
        downloadQueue.sync {
            downloadStates.removeAll()
            downloadProgressCache.removeAll()
            downloadStartTimes.removeAll()
            lastDownloadedBytes.removeAll()
        }
    }
    
    /// 重置下载状态
    func resetDownloadStates() {
        downloadQueue.sync {
            downloadStates.removeAll()
            downloadProgressCache.removeAll()
            downloadStartTimes.removeAll()
            lastDownloadedBytes.removeAll()
        }
    }
    
    // MARK: - 公共访问方法
    
    /// 获取主模型下载管理器（用于重置状态）
    var mainModelManager: MBModelDownloadHelperV2? {
        return modelV26_Q4_K_M_Manager
    }
    
    /// 获取VIT模型下载管理器（用于重置状态）
    var vitModelManager: MBModelDownloadHelperV2? {
        return mmprojV26_Manager
    }
    
    /// 获取ANE模块下载管理器（用于重置状态）
    var aneModelManager: MBModelDownloadHelperV2? {
        return mlmodelcV26_Manager
    }
} 
