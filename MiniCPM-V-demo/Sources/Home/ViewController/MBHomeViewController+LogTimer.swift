//
//  MBHomeViewController+LogTimer.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/20.
//

import Foundation

/// 性能日志 timer
extension MBHomeViewController {

    /// 开启：性能日志 Timer
    ///
    /// 必须在 main RunLoop 上 schedule，否则 background thread 上 attach 的 Timer
    /// 永远不会 fire，logTimeSecond 不增长，UI 上"预处理耗时"会显示成 0.0s。
    /// 内部统一 dispatch 到 main，使得调用方可以从任何线程（包括 Task.detached）
    /// 安全调用，不需要外面再包一层。
    func startLogTimer() {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }

            // 先把上一轮残留 timer 干掉，避免连续选图时多份 timer 并存
            self.logTimer?.invalidate()
            self.logTimer = nil
            self.logTimeSecond = 0

            // 用 RunLoop.main.add(_:forMode:.common) 而不是 scheduledTimer，
            // 既显式声明 RunLoop，也保证滚动 UITableView 时（tracking mode）
            // timer 仍然 fire。
            //
            // interval 选 0.5s（2 Hz）—— 之前是 0.1s（10 Hz），视频抽帧期间每秒 10 次
            // cellForRow + bindImageWith + property writes 持续吃 main runloop slot，
            // 用户点别的按钮时延迟可感。0.5s 已经足够看见进度条 tick 跳动 + 文字
            // 实时累积，但把 main 上的额外干扰降低 5×。logTimeSecond 跟着 step 改成
            // 0.5（见 logTimerFire），保持耗时显示的基线一致。
            let t = Timer(timeInterval: 0.5,
                          target: self,
                          selector: #selector(self.logTimerFire),
                          userInfo: nil,
                          repeats: true)
            RunLoop.main.add(t, forMode: .common)
            self.logTimer = t
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
    
    /// Timer 更新
    @objc func logTimerFire() {
        
        // find image cell and update log
        DispatchQueue.main.async {
            // 步进必须跟 startLogTimer 里的 timeInterval 对齐，否则 logTimeSecond
            // 跟墙钟脱节，后续基于 logTimeSecond 算的进度百分比会失真。
            self.logTimeSecond += 0.5
            if self.dataArray.count > 0 {
                if let latestCell = self.tableView.cellForRow(at: IndexPath(row: self.dataArray.count - 1, section: 0)) as? MBImageTableViewCell {
                    if latestCell.model?.role == "user",
                       latestCell.model?.contentImage != nil {
                        
                        // 更新性能日志
                        
                        if self.totalVideoFrameCount == 0 {
                            // 图片路径：把 totalVideoFrameCount 当 1 用，方便下面进度估算。
                            self.totalVideoFrameCount = 1
                        }

                        // size 直接用源文件字节数（图片是单图大小、视频是 .mov/.mp4 整体大小）。
                        // 旧 bug：这里曾经 * totalVideoFrameCount，把 10MB 视频显示成 ~640MB。
                        let size = MBHomeViewController.formatBytesAsKBMB(self.outputImageFileSize)

                        latestCell.model?.performLog = "\(Int(self.outputImageView.image?.size.width ?? 0))x\(Int(self.outputImageView.image?.size.height ?? 0)) (\(size))"
                        
                        // 更新图片处理的进度
                        // 绿色进度条，预测的耗时时长提 (MAX(image.width, image.height) * 2 + 1) * (一 frame 用时 4-8s)s + (llm 用时 8-10)s = 总耗时
                        let imgWidth = self.outputImageView.image?.size.width ?? 0
                        let imgHeight = self.outputImageView.image?.size.height ?? 0
                        
                        // 切片数量
                        let clipCount = floor(max(imgWidth/448, imgHeight/448)) * 1 + 1
                        var totalTime = Int(clipCount * 4 + 7)
                        // 例如切了 5 片，则总时长大约就是 5 * 4 + 6 = 26s
                        // 则我们可以在每 3 秒（可以整除）的时候，更新进度
                        
                        if self.outputImageURL?.absoluteString.hasSuffix("mov") == true ||
                            self.outputImageURL?.absoluteString.hasSuffix("mp4") == true {
                            // 是视频，则总时长应该和视频的大小有关
                            totalTime = Int(self.totalVideoFrameCount * 4 + 7)
                            debugLog("选中的是视频，所有预计总时长为：\(self.logTimeSecond) : \(totalTime)")
                        }
                        
                        // 计算进度百分比
                        var percent = CGFloat(self.logTimeSecond) / CGFloat(totalTime)
                        
                        // 让进度条增长得更快，使用更激进的加速策略
                        // 前期快速增长，后期稍微慢一些，但不会停在90%
                        if percent < 0.2 {
                            // 前20%时间，进度条快速增长到70%
                            percent = percent * 3.5
                        } else if percent < 0.5 {
                            // 20%-50%时间，进度条从70%增长到95%
                            percent = 0.7 + (percent - 0.2) * 0.83
                        } else {
                            // 50%以后，进度条从95%增长到100%
                            percent = 0.95 + (percent - 0.5) * 0.1
                        }
                        
                        // 确保不超过100%
                        percent = min(percent, 1.0)
                        
                        // 更新进度条
                        latestCell.model?.processProgress = percent
                        
                        latestCell.bindImageWith(data: latestCell.model)
                    }
                }
            }
        }
    }
    
    /// 停止 Timer
    ///
    /// 与 startLogTimer 对称：内部统一在 main 上 invalidate。
    /// 注意不要在这里清掉 logTimeSecond，调用方往往需要先读它再 stop
    /// （见 prepareLoadModelAddImageToCell 的兜底分支）。
    func stopLogTimer() {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.logTimer?.invalidate()
            self.logTimer = nil
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
