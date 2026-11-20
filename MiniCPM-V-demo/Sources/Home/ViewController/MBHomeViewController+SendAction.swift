//
//  MBHomeViewController+SendAction.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/7/12.
//

import Foundation
import UIKit

/// 点击「发送」按钮，逻辑处理
extension MBHomeViewController {

    // MARK: - 多模态模型的处理逻辑
    
    /// 多模态模型的处理逻辑
    func processImageAndTextMixModeSendLogic() async {

        // 模型还没加载完成就允许发送，addTextInBackground 会在底层抛
        // MTMDError.contextNotInitialized，但 Bool 版 wrapper 会把错误吞掉，
        // UI 上的症状是"用户消息发出去了、llm 没回复"，看起来像 App 卡死。
        // 这里和图片 / 视频路径对齐做一次状态 gating，给一个明确 toast。
        if self.mtmdWrapperExample?.multiModelLoadingSuccess != true {
            self.showErrorTips(L.Home.tipModelNotReady.loc)
            return
        }

        // 如果有录像的在处理中的视频帧，也要等
        if MBLiveCaptureVideoFrameManager.shared.capturedImageArray.count != 0 {
            self.showErrorTips(L.Home.tipImageProcessing.loc)
            return
        }

        // 单张图 prefill 还没完成时，禁止并发提问。
        // mtmd_context 是单状态机：prefill_image 推进 ctx->n_past 的过程中，
        // 如果 prefill_text 在 DispatchQueue.global 上并发跑，会读到错乱的
        // n_past，最终模型不返回 / 输出胡乱的内容（用户报的"没回复"症状）。
        // 给一个明确的 toast 比静默丢弃发送更友好。
        if self.uploadSingleImageToModel {
            self.showErrorTips(L.Home.tipImageProcessing.loc)
            return
        }

        let inputText = textInputView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 把文字也转换为 cell 放到 UITableView 上
        appendTextDataToCellWith(text: inputText, role: "user")

        // 记录用户输入（总是记录用户最后的输入）
        latestUserInputText = inputText

        // 所有这一切处理完成后，才清空用户输入的内容
        textInputView.text = ""
        sendButton.isEnabled = false
        placeholderLabel.isHidden = false
        
        // 把之前显示在 llm cell 上的 toolbar 及 popup 都隐藏掉，注意，不能把下边即将要输出显示的 llm cell 隐藏了。
        hideAllCellToolbarAndPopup()

        // append robte output text cell, prepare llm output
        appendTextDataToCellWith(text: "", role: "llm")
        
        // 滚动到底部（用户主动发消息，强制滚并解除「触摸暂停」）
        reloadAndScrollToBottom(force: true)
        
        // 清空输出
        mtmdWrapperExample?.outputText = ""
        mtmdWrapperExample?.performanceLog = ""
        
        // 显示暂停和继续的悬浮的按钮
        showFloatingActionViewWith(show: true)
        
        // 清空 perflog
        self.cachedImageEmbeddingPerfLog.removeAll()

        let ret = await mtmdWrapperExample?.addTextInBackground(inputText)

        if ret != true, mtmdWrapperExample?.isContextFull == true {
            await MainActor.run { self.showErrorTips(L.Home.contextFull.loc, delay: 4) }
        }

        if ret == true {
            Task {
                await mtmdWrapperExample?.startGeneration()
            }
        }
    }
}
