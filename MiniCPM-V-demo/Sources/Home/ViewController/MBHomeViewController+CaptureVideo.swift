//
//  MBHomeViewController+CaptureVideo.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/7/18.
//

import Foundation
import UIKit

extension MBHomeViewController {
    
    @objc func registVideoProcessCompleteNotification(notification: NSNotification?) {

        DispatchQueue.main.async {

            // 这是总耗时的时候长（包括 embedding(:) 和 process_input(:) 这两个步骤）
            let lastLogTime = self.logTimeSecond

            // 初始化完成，停止性能日志定时器
            self.stopLogTimer()

            // 记录日志
            if self.dataArray.count > 0,
               let latestCell = self.tableView.cellForRow(at: IndexPath(row: self.dataArray.count - 1, section: 0)) as? MBImageTableViewCell {
                if latestCell.model?.role == "user",
                   latestCell.model?.contentImage != nil {

                    let sizeStr = MBHomeViewController.formatBytesAsKBMB(self.outputImageFileSize)
                    // 实时录像分支：用 logTimer 累计的 logTimeSecond。Timer 已经
                    // 是 0.1s 精度的 Double，直接 %.1f 格式化即可。不要再去拼
                    // arc4random()%6+1 这种"伪小数 hack"，会拼出 "5.3.4s" 这种
                    // 非法时间字符串。
                    let perfLog = String(format: "\t\t预处理耗时：%.1fs", lastLogTime)

                    // 处理完成后，这个值总是 -1
                    latestCell.model?.processProgress = -1

                    latestCell.model?.performLog = "\(Int(self.outputImageView.image?.size.width ?? 0))x\(Int(self.outputImageView.image?.size.height ?? 0)) (\(sizeStr)) \(perfLog)"
                    latestCell.bindImageWith(data: latestCell.model)

                    self.outputImageView.image = nil
                }
            }

        }

    }
    
    /// 实时捕获视频按钮
    @objc public func handleCaptureVideo(_ sender: UIButton) {
        
        if !MBVideoSerialProcessQueueManager.shared.isQueueEmpty {
            self.showErrorTips("上一个视频还在解析中，请稍等", delay: 3)
            return
        }
        
        // 收起键盘先
        self.textInputView.resignFirstResponder()
        
        // 点击单独的录像按钮功能时，先加载多模态模型
        // 为了保证效果，进入录像按钮，总是 reset llama state
        // 启动 home vc 就加载多模态模型
        self.imageLoaded = false
        self.checkMultiModelLoadStatusAndLoadIt()
        
        // 弹出相机预览界面
        let vc = SwiftyCameraMainViewController()
        
        // 「X」关闭按钮回调
        vc.dismissVCHandler = { [weak self] _ in
            debugLog("-->> 关闭录像 ViewController。")
            MBLiveCaptureVideoFrameManager.shared.captureVideoFrameStatus = false
            self?.captureVideoFrameStatus = false
            self?.tableView.reloadData()
            
            self?.liveStreamVCShow = false
            self?.liveStreamVC = nil
            
            Task {
                await self?.mtmdWrapperExample?.reset()
                self?.imageLoaded = false
            }
        }
        
        // 模型只能被加载一次，所以只能 share 状态机，等做车机 demo 时，在入口处就划分来两个不同的状态机才行
        vc.llamaState = self.mtmdWrapperExample
        
        vc.modalPresentationStyle = .fullScreen
        
        self.present(vc, animated: true)
        
        // 保存起来
        liveStreamVC = vc
        self.liveStreamVCShow = true
    }
}


extension MBHomeViewController {
    
    /// 处理 video frame
    ///
    /// MiniCPM-V 4.6 视频理解的约定：
    /// - 1fps 抽帧，超 64 帧则均匀抽 64 帧（在 MBVideoFrameExtractor 里完成）；
    /// - **每帧 slice = 1**，即只过 overview、不切片，避免 prefill token 数失控；
    /// - 不使用 image_id（mtmd_ios_prefill_frame 走 default media marker，本就不带 id）。
    ///
    /// slice=1 的切换走 `liveSetImageMaxSliceNums`，只动当前 mtmd_context，
    /// 不写 UserDefaults，结束后立即恢复用户在设置页选的 slice 值。
    ///
    /// 耗时统计：用 `Date()` 取墙钟时间。logTimer 仍然启动，用于驱动 cell
    /// 进度条 / 实时 size 文字。**不**用 `logTimeSecond` 写最终耗时——
    /// Timer 在 main RunLoop 上跑，长视频时容易被 prefill 期间的 UI 任务
    /// 拖累而少计 tick，导致显示比实际耗时少 1-2 秒。
    func processVideoFrame(images: [UIImage]) async {

        // 必须要先加载成功模型才行
        if self.mtmdWrapperExample?.multiModelLoadingSuccess == false {
            return
        }

        // 视频开 turn 前先把 KV 清干净，跟 Python 端 model.chat(msgs=[...]) 行为对齐
        // ——视频是"新一段对话"，不携带前序图文 chat 历史。这样还顺带规避了 n_ctx 溢出：
        // 长对话累积到接近 n_ctx 上限时，再叠加几十帧 × 几十 token/帧的视频 prefill
        // 必然撞 llama_decode 失败，而 MiniCPM-V 4.6 的 hybrid SSM+Attn 模型一旦
        // mid-prefill 失败、KV 又无法 partial truncate (SSM 不支持)，整个 ctx 就死锁
        // 在 "X(KV) >= Y(n_past) 永远不变" 的状态里，所有后续 prefill_text /
        // prefill_frame 都连环失败 (M-RoPE 一致性检查)。
        self.mtmdWrapperExample?.clearKVCacheForNewTurn()

        // 保存这一轮视频抽帧的数量，用以进度条更新处理
        self.totalVideoFrameCount = images.count

        // 启动 logTimer：驱动 cell 进度条 + 实时 size 文字（来自 +LogTimer 里
        // logTimerFire）。真实耗时另用墙钟单独计量，最后写到 cell 的 perfLog。
        self.startLogTimer()
        let processStart = Date()

        // 视频帧专用：仅在 v46 上启用 slice=1 临时切换；老模型维持用户原 slice 值。
        let isV46 = self.mtmdWrapperExample?.currentUsingModelType == .V46MultiModel
        if isV46 {
            self.mtmdWrapperExample?.liveSetImageMaxSliceNums(1)
            debugLog("-->> [video] v46 路径：临时切到 slice=1，共 \(images.count) 帧。")
        }

        // part.2 循环地把视频帧编码（embed）并 input 到模型里
        for (index, img) in images.enumerated() {
            // 放在串行队列中去处理
            let ret = await MBVideoSerialProcessQueueManager.shared.serialProcessVideoFrame(image: img,
                                                                                            index: index,
                                                                                            mtmdWrapperExample: self.mtmdWrapperExample,
                                                                                            embedType: .VideoFrame)
            debugLog("-->> index = \(index), img=\(img), ret=\(ret).")
            // end for
        }

        // 兜底恢复 slice cap：读取 UserDefaults 最新值，避免视频处理期间用户在
        // 切图设置面板调过滑条后被回滚到"开始时缓存的旧值"。
        if isV46 {
            let finalSlice = ImageSliceSetting.current
            self.mtmdWrapperExample?.liveSetImageMaxSliceNums(finalSlice)
            debugLog("-->> [video] v46 路径：slice 已恢复为 \(finalSlice)。")
        }

        let imageCount = images.count
        let elapsed = Date().timeIntervalSince(processStart)
        // 帧的真实分辨率取第一帧（抽帧用的都是同一个 AVAsset 同分辨率）。
        // outputImageView.image 是输入框旁边的小缩略图，已经走 transform，
        // 可能正在被 main async 队列里清空，不能依赖它读宽高。
        let firstFrameSize = images.first?.size ?? .zero
        let videoFileBytes = self.outputImageFileSize

        // part.7 更新总时长到最后一个 cell 的 perflog 里
        DispatchQueue.main.async {

            // 初始化完成，停止性能日志定时器
            self.stopLogTimer()

            // 有过图文对话了，更新标记
            self.hasImageAndTextConversation = true

            // 记录日志
            if self.dataArray.count > 0,
               let latestCell = self.tableView.cellForRow(at: IndexPath(row: self.dataArray.count - 1, section: 0)) as? MBImageTableViewCell {
                if latestCell.model?.role == "user",
                   latestCell.model?.contentImage != nil {

                    // size 直接用视频文件大小。不要 * imageCount，否则 10MB 视频
                    // 会被显示成几百 MB（旧 bug：错把 outputImageFileSize 当成
                    // "单帧大小"乘了帧数）。
                    let sizeStr = MBHomeViewController.formatBytesAsKBMB(videoFileBytes)
                    let timeStr = String(format: "%.1f", elapsed)
                    let perfLog = "\t\t视频抽帧 \(imageCount) 帧，预处理耗时：\(timeStr)s"

                    // 处理完成后，这个值总是 -1
                    latestCell.model?.processProgress = -1

                    latestCell.model?.performLog = "\(Int(firstFrameSize.width))x\(Int(firstFrameSize.height)) (\(sizeStr)) \(perfLog)"
                    latestCell.bindImageWith(data: latestCell.model)
                }
            }

            // 使用过一次就清除
            self.outputImageView.image = nil
        }

        self.totalVideoFrameCount = 0
    }
}

extension MBHomeViewController {

    /// 把字节数格式化为 "X KB" 或 "X MB"（按 1000 进位，保留 UI 旧文案风格）。
    /// 共享给视频路径 (processVideoFrame) 和 LogTimer (logTimerFire) 使用，
    /// 避免重复实现导致一边修了另一边没修的老 bug。
    static func formatBytesAsKBMB(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let kb = Double(bytes) / 1000.0
        if kb < 1000 {
            return String(format: "%.0f KB", ceil(kb))
        } else {
            return String(format: "%.0f MB", ceil(kb / 1000.0))
        }
    }
}
