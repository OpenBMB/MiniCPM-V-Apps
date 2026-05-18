//
//  MBSettingsModelDownloadManager.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 12/7/2025.
//

import Foundation
import UIKit
import ZipArchive

/// 下载状态枚举
enum DownloadStatus {
    case notStarted
    case downloading
    case paused
    case completed
    case failed
}

/// 下载进度信息结构
struct DownloadProgressInfo {
    let modelName: String
    let status: DownloadStatus
    let progress: CGFloat
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speed: Double // bytes per second
    let estimatedTimeRemaining: TimeInterval
}

/// V4 模型下载管理器单例
class MBV4ModelDownloadManager: NSObject {
    
    // MARK: - 单例实现
    
    static let shared = MBV4ModelDownloadManager()
    
    private override init() {
        super.init()
    }
    
    // MARK: - 属性
    
    /// 外部传入的 MTMDWrapperExample 引用
    private var mtmdWrapperExample: MTMDWrapperExample?
    
    /// V4 主模型下载管理器
    private var modelv4_Q4_K_M_Manager: MBModelDownloadHelperV2?
    
    /// V4 mmproj VIT 模型下载管理器
    private var mmprojv4_Manager: MBModelDownloadHelperV2?
    
    /// V4 ANE 模块下载管理器
    private var mlmodelcv4_Manager: MBModelDownloadHelperV2?
    
    /// 下载进度回调
    var progressHandler: ((String, CGFloat) -> Void)?
    
    /// 下载完成回调
    var completionHandler: ((String, Bool) -> Void)?
    
    /// 详细进度信息回调
    var detailedProgressHandler: ((DownloadProgressInfo) -> Void)?
    
    // MARK: - 防重复调用机制
    
    /// 下载状态跟踪
    private var downloadStates: [String: DownloadStatus] = [:]
    
    /// 下载进度缓存
    private var downloadProgressCache: [String: DownloadProgressInfo] = [:]
    
    /// 下载开始时间记录
    private var downloadStartTimes: [String: Date] = [:]
    
    /// 上次下载字节数记录（用于计算速度）
    private var lastDownloadedBytes: [String: Int64] = [:]
    
    /// 防重复调用锁
    private let downloadQueue = DispatchQueue(label: "com.minicpm.v4.download", qos: .userInitiated)
    
    /// 检查是否正在下载指定模型
    private func isDownloading(_ modelKey: String) -> Bool {
        return downloadQueue.sync {
            return downloadStates[modelKey] == .downloading
        }
    }
    
    /// 设置下载状态
    private func setDownloadStatus(_ status: DownloadStatus, for modelKey: String) {
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
    
    /// 初始化下载管理器
    /// - Parameter llamaState: llama状态管理器
    func setupDownloadManager(with wrapper: MTMDWrapperExample) {
        self.mtmdWrapperExample = wrapper
        setupModels()
    }
    
    /// 配置所有V4模型
    private func setupModels() {
        guard let mtmdWrapperExample = mtmdWrapperExample else { return }
        
        // V4 主模型
        let modelv4_Q4_K_M_URLString = MiniCPMModelConst.modelv4_Q4_K_M_URLString
        modelv4_Q4_K_M_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.modelv4_Q4_K_M_FileName,
            modelUrl: modelv4_Q4_K_M_URLString,
            filename: MiniCPMModelConst.modelv4_Q4_K_M_FileName,
            backupModelUrl: MiniCPMModelConst.modelv4_Q4_K_M_BackUpURLString
        )
        
        // V4 mmproj VIT 模型
        let mmprojv4_URLString = MiniCPMModelConst.mmprojv4_URLString
        mmprojv4_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.mmprojv4_FileName,
            modelUrl: mmprojv4_URLString,
            filename: MiniCPMModelConst.mmprojv4_FileName,
            backupModelUrl: MiniCPMModelConst.mmprojv4_BackUpURLString
        )
        
        // V4 ANE 模块
        let mlmodelcv4_URLString = MiniCPMModelConst.mlmodelcv4_ZipFileURLString
        mlmodelcv4_Manager = MBModelDownloadHelperV2(
            wrapper: mtmdWrapperExample,
            modelName: MiniCPMModelConst.mlmodelcv4_ZipFileName,
            modelUrl: mlmodelcv4_URLString,
            filename: MiniCPMModelConst.mlmodelcv4_ZipFileName,
            backupModelUrl: MiniCPMModelConst.mlmodelcv4_ZipFileBackUpURLString
        )
        
        // 恢复断点续传
        restoreDownloadProgress()
    }
    
    /// 恢复下载进度
    private func restoreDownloadProgress() {
        guard let info = FDownLoaderManager.shareInstance().downLoaderInfo else { return }
        
        // 恢复 V4 主模型下载进度
        let modelv4_Q4_K_M_FileName = String(stringLiteral: MiniCPMModelConst.modelv4_Q4_K_M_URLString).md5() ?? ""
        if let obj = info[modelv4_Q4_K_M_FileName] as? FDownLoader {
            if obj.state == .downLoading {
                downloadModelv4_Q4_K_M()
            }
        }
        
        // 恢复 V4 mmproj 模型下载进度
        let mmprojv4_FileName = String(stringLiteral: MiniCPMModelConst.mmprojv4_URLString).md5() ?? ""
        if let obj = info[mmprojv4_FileName] as? FDownLoader {
            if obj.state == .downLoading {
                downloadMMProjv4()
            }
        }
        
        // 恢复 V4 ANE 模块下载进度
        let mlmodelcv4_FileName = String(stringLiteral: MiniCPMModelConst.mlmodelcv4_ZipFileURLString).md5() ?? ""
        if let obj = info[mlmodelcv4_FileName] as? FDownLoader {
            if obj.state == .downLoading {
                downloadMLModelcv4()
            }
        }
    }

    // MARK: - reconcile / readiness（V4.6 同款）

    /// 用磁盘上的文件存在情况强制 reconcile helper.status，**完全按磁盘真相重写**。
    /// - LLM / mmproj：Documents 下对应 gguf 存在 → downloaded，否则 download
    /// - ANE：解压后的 .mlmodelc/.mlpackage 目录存在且非空 → downloaded；
    ///        否则一律 download（zip 残留不算就绪，避免误判）
    func reconcileStatusFromDisk() {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default

        let llmPath = docs.appendingPathComponent(MiniCPMModelConst.modelv4_Q4_K_M_FileName).path
        modelv4_Q4_K_M_Manager?.status = fm.fileExists(atPath: llmPath) ? "downloaded" : "download"

        let mmprojPath = docs.appendingPathComponent(MiniCPMModelConst.mmprojv4_FileName).path
        mmprojv4_Manager?.status = fm.fileExists(atPath: mmprojPath) ? "downloaded" : "download"

        mlmodelcv4_Manager?.status = isMLModelcv4Ready() ? "downloaded" : "download"
    }

    /// V4 ANE 解压后目录是否就绪（与 V46 同语义）
    private func isMLModelcv4Ready() -> Bool {
        let docs = getDocumentsDirectory()
        let fm = FileManager.default
        // 推断解压后的目录名：去掉 zip 后缀；同时给 mlpackage 备选
        let stem = (MiniCPMModelConst.mlmodelcv4_ZipFileName as NSString).deletingPathExtension
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

    // MARK: - 一键下载（V4.6 同款）

    /// 一键下载：默认只拉 LLM + VPM 两段（ANE/CoreML 包默认禁用，参见 MBV4ModelDetailViewController 注释）。
    func downloadAll() {
        reconcileStatusFromDisk()
        debugLog("-->> V4 一键下载：同时拉起 LLM + VPM（ANE 已默认禁用）")
        downloadModelv4_Q4_K_M()
        downloadMMProjv4()
        // downloadMLModelcv4()  // ANE 暂禁用，恢复时取消注释
    }

    /// 综合进度，0..1。ANE 当前不参与，故不计入。
    func overallProgress() -> CGFloat {
        let mainProg   = progress(forKey: "v4_main_model")
        let mmprojProg = progress(forKey: "v4_mmproj_model")
        // let aneProg = progress(forKey: "v4_ane_module")  // ANE 暂禁用
        return (mainProg + mmprojProg) / 2.0
    }

    private func progress(forKey modelKey: String) -> CGFloat {
        let status: String
        switch modelKey {
        case "v4_main_model":   status = getModelv4_Q4_K_M_Status()
        case "v4_mmproj_model": status = getMMProjv4_Status()
        case "v4_ane_module":   status = getMLModelcv4_Status()
        default: status = "download"
        }
        if status == "downloaded" { return 1.0 }
        if let info = downloadQueue.sync(execute: { downloadProgressCache[modelKey] }) {
            return info.progress
        }
        return 0
    }

    /// 比 hasAnyModelDownloading 更可靠：先 reconcile，再判断"还有未完成的下载任务"。
    /// 已经在磁盘上落地的 key 即使 downloadStates 残留 .downloading 也会被忽略，
    /// 避免出现"全部下完但 helper.status 没切到 downloaded，按钮卡 100%"。
    func hasAnyDownloadActive() -> Bool {
        reconcileStatusFromDisk()

        let mainDone = (modelv4_Q4_K_M_Manager?.status == "downloaded")
        let mmprojDone = (mmprojv4_Manager?.status == "downloaded")
        let aneDone = (mlmodelcv4_Manager?.status == "downloaded")

        return downloadQueue.sync {
            for (key, state) in downloadStates {
                guard state == .downloading || state == .paused else { continue }
                switch key {
                case "v4_main_model":   if mainDone   { continue }
                case "v4_mmproj_model": if mmprojDone { continue }
                case "v4_ane_module":   if aneDone    { continue }
                default: break
                }
                return true
            }
            return false
        }
    }

    // MARK: - 下载方法（带防重复调用）
    
    /// 下载 V4 主模型
    func downloadModelv4_Q4_K_M() {
        let modelKey = "v4_main_model"
        
        guard !isDownloading(modelKey) else {
            debugLog("-->> V4主模型正在下载中，忽略重复调用")
            return
        }
        // 已下载就直接跳过；不再做"全局只允许一个"互斥，让一键下载能并行三段
        if getModelv4_Q4_K_M_Status() == "downloaded" {
            debugLog("-->> V4主模型已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        modelv4_Q4_K_M_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    // 下载完成，进行MD5校验
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyModelv4_Q4_K_M_MD5()
                    self.progressHandler?(MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.modelv4_Q4_K_M_DisplayedName)
                    }
                }
            }
        })
    }
    
    /// 下载 V4 mmproj VIT 模型
    func downloadMMProjv4() {
        let modelKey = "v4_mmproj_model"
        
        guard !isDownloading(modelKey) else {
            debugLog("-->> V4 VIT模型正在下载中，忽略重复调用")
            return
        }
        if getMMProjv4_Status() == "downloaded" {
            debugLog("-->> V4 VIT模型已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        mmprojv4_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    // 下载完成，进行MD5校验
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyMMProjv4_MD5()
                    self.progressHandler?(MiniCPMModelConst.modelMMProjv4_DisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.modelMMProjv4_DisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.modelMMProjv4_DisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.modelMMProjv4_DisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.modelMMProjv4_DisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.modelMMProjv4_DisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.modelMMProjv4_DisplayedName)
                    }
                }
            }
        })
    }
    
    /// 下载 V4 ANE 模块
    func downloadMLModelcv4() {
        let modelKey = "v4_ane_module"
        
        guard !isDownloading(modelKey) else {
            debugLog("-->> V4 ANE模块正在下载中，忽略重复调用")
            return
        }
        if getMLModelcv4_Status() == "downloaded" {
            debugLog("-->> V4 ANE模块已下载完成")
            return
        }
        
        setDownloadStatus(.downloading, for: modelKey)
        
        mlmodelcv4_Manager?.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if progress >= 1 {
                    // 下载完成，进行MD5校验和解压缩
                    self.setDownloadStatus(.completed, for: modelKey)
                    self.verifyAndExtractMLModelcv4()
                    self.progressHandler?(MiniCPMModelConst.mlmodelcv4_ZipFileDisplayedName, 1.0)
                    self.completionHandler?(MiniCPMModelConst.mlmodelcv4_ZipFileDisplayedName, true)
                    self.updateDownloadProgress(1.0, for: modelKey, modelName: MiniCPMModelConst.mlmodelcv4_ZipFileDisplayedName)
                } else {
                    if status == "failed" {
                        self.setDownloadStatus(.failed, for: modelKey)
                        self.progressHandler?(MiniCPMModelConst.mlmodelcv4_ZipFileDisplayedName + "下载失败", -1)
                        self.completionHandler?(MiniCPMModelConst.mlmodelcv4_ZipFileDisplayedName, false)
                    } else {
                        self.progressHandler?(MiniCPMModelConst.mlmodelcv4_ZipFileDisplayedName, progress)
                        self.updateDownloadProgress(progress, for: modelKey, modelName: MiniCPMModelConst.mlmodelcv4_ZipFileDisplayedName)
                    }
                }
            }
        })
    }
    
    // MARK: - 下载进度查看方法
    
    /// 获取指定模型的下载进度信息
    /// - Parameter modelKey: 模型标识符
    /// - Returns: 下载进度信息
    func getDownloadProgress(for modelKey: String) -> DownloadProgressInfo? {
        return downloadQueue.sync {
            return downloadProgressCache[modelKey]
        }
    }
    
    /// 获取所有模型的下载进度信息
    /// - Returns: 所有模型的下载进度信息字典
    func getAllDownloadProgress() -> [String: DownloadProgressInfo] {
        return downloadQueue.sync {
            return downloadProgressCache
        }
    }
    
    /// 获取指定模型的下载状态
    /// - Parameter modelKey: 模型标识符
    /// - Returns: 下载状态
    func getDownloadStatus(for modelKey: String) -> DownloadStatus {
        return downloadQueue.sync {
            return downloadStates[modelKey] ?? .notStarted
        }
    }
    
    /// 获取所有模型的下载状态
    /// - Returns: 所有模型的下载状态字典
    func getAllDownloadStatus() -> [String: DownloadStatus] {
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
    
    /// 校验 V4 主模型 MD5（off-main，详见 V46 同款 verify 注释）
    private func verifyModelv4_Q4_K_M_MD5() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.modelv4_Q4_K_M_FileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checksum = MBUtils.md5(for: fileURL)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let checksum = checksum {
                    debugLog("-->> V4主模型 实际MD5值: \(checksum)")
                    debugLog("-->> V4主模型 期望MD5值: \(MiniCPMModelConst.modelv4_Q4_K_M_MD5)")
                    if checksum == MiniCPMModelConst.modelv4_Q4_K_M_MD5 {
                        debugLog("-->> V4主模型 MD5校验成功: \(checksum)")
                        self.modelv4_Q4_K_M_Manager?.status = "downloaded"
                    } else {
                        debugLog("-->> V4主模型 MD5校验失败")
                        self.modelv4_Q4_K_M_Manager?.status = "download"
                        self.deleteModelv4_Q4_K_M()
                    }
                } else {
                    debugLog("-->> V4主模型 MD5计算失败")
                    self.modelv4_Q4_K_M_Manager?.status = "download"
                    self.deleteModelv4_Q4_K_M()
                }
            }
        }
    }

    /// 校验 V4 mmproj 模型 MD5（off-main）
    private func verifyMMProjv4_MD5() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mmprojv4_FileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checksum = MBUtils.md5(for: fileURL)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let checksum = checksum {
                    debugLog("-->> V4 VIT模型 实际MD5值: \(checksum)")
                    debugLog("-->> V4 VIT模型 期望MD5值: \(MiniCPMModelConst.modelMMProjv4_MD5)")
                    if checksum == MiniCPMModelConst.modelMMProjv4_MD5 {
                        debugLog("-->> V4 VIT模型 MD5校验成功: \(checksum)")
                        self.mmprojv4_Manager?.status = "downloaded"
                    } else {
                        debugLog("-->> V4 VIT模型 MD5校验失败")
                        self.mmprojv4_Manager?.status = "download"
                        self.deleteMMProjv4()
                    }
                } else {
                    debugLog("-->> V4 VIT模型 MD5计算失败")
                    self.mmprojv4_Manager?.status = "download"
                    self.deleteMMProjv4()
                }
            }
        }
    }

    /// 校验并解压 V4 ANE 模块（off-main：MD5 + zip 解压都在 background 跑）
    private func verifyAndExtractMLModelcv4() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mlmodelcv4_ZipFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?._verifyAndExtractMLModelcv4_offMain(fileURL: fileURL)
        }
    }

    private func _verifyAndExtractMLModelcv4_offMain(fileURL: URL) {
        guard let checksum = MBUtils.md5(for: fileURL) else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V4 ANE模块 MD5计算失败")
                self?.mlmodelcv4_Manager?.status = "download"
                self?.deleteMLModelcv4()
            }
            return
        }

        debugLog("-->> V4 ANE模块 实际MD5值: \(checksum)")
        debugLog("-->> V4 ANE模块 期望MD5值: \(MiniCPMModelConst.mlmodelcv4_ZipFileMD5)")

        guard checksum == MiniCPMModelConst.mlmodelcv4_ZipFileMD5 else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V4 ANE模块 MD5校验失败")
                self?.mlmodelcv4_Manager?.status = "download"
                self?.deleteMLModelcv4()
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
                debugLog("-->> V4 ANE模块解压失败: \(error.localizedDescription)")
                self?.mlmodelcv4_Manager?.status = "download"
                self?.deleteMLModelcv4()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                debugLog("-->> V4 ANE模块解压成功")
                self?.mlmodelcv4_Manager?.status = "downloaded"
            }
        }
    }
    
    // MARK: - 删除方法
    
    /// 删除 V4 主模型
    func deleteModelv4_Q4_K_M() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.modelv4_Q4_K_M_FileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            modelv4_Q4_K_M_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v4_main_model")
            debugLog("-->> V4主模型删除成功")
        } catch {
            debugLog("-->> V4主模型删除失败: \(error.localizedDescription)")
        }
    }
    
    /// 删除 V4 mmproj 模型
    func deleteMMProjv4() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mmprojv4_FileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            mmprojv4_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v4_mmproj_model")
            debugLog("-->> V4 VIT模型删除成功")
        } catch {
            debugLog("-->> V4 VIT模型删除失败: \(error.localizedDescription)")
        }
    }
    
    /// 删除 V4 ANE 模块
    func deleteMLModelcv4() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MiniCPMModelConst.mlmodelcv4_ZipFileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            mlmodelcv4_Manager?.status = "download"
            setDownloadStatus(.notStarted, for: "v4_ane_module")
            debugLog("-->> V4 ANE模块删除成功")
        } catch {
            debugLog("-->> V4 ANE模块删除失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 状态查询方法
    
    /// 获取 V4 主模型状态
    func getModelv4_Q4_K_M_Status() -> String {
        return modelv4_Q4_K_M_Manager?.status ?? "download"
    }
    
    /// 获取 V4 mmproj 模型状态
    func getMMProjv4_Status() -> String {
        return mmprojv4_Manager?.status ?? "download"
    }
    
    /// 获取 V4 ANE 模块状态
    func getMLModelcv4_Status() -> String {
        return mlmodelcv4_Manager?.status ?? "download"
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
        return modelv4_Q4_K_M_Manager
    }
    
    /// 获取VIT模型下载管理器（用于重置状态）
    var vitModelManager: MBModelDownloadHelperV2? {
        return mmprojv4_Manager
    }
    
    /// 获取ANE模块下载管理器（用于重置状态）
    var aneModelManager: MBModelDownloadHelperV2? {
        return mlmodelcv4_Manager
    }
}
