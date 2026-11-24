//
//  MBHomeViewController+SubscribeMessageLog.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/21.
//

import Foundation
import llama

extension MBHomeViewController {
    
    /// 订阅大模型的输出-original
    public func subscriberLlamaMessageLog() {
        
        // 订阅 @Published 属性的变化
        dataSubscriber = mtmdWrapperExample?.$outputText
            .receive(on: DispatchQueue.main)   // 更新 UI 的相关操作切换到主线程
            .sink { [weak self] receivedData in
                
                // find last text cell and append text
                if self?.liveStreamVCShow == false,
                   let c = self?.dataArray.count, c > 0 {
                    if let latestCell = self?.tableView.cellForRow(at: IndexPath(row: (self?.dataArray.count ?? 0) - 1, section: 0)) as? MBTextTableViewCell {
                        
                        if latestCell.model?.role == "llm", !receivedData.isEmpty {
                            
                            latestCell.model?.contentText = receivedData
                            // 「实时速度」：流式期间把 decode t/s 写进 speedLog，工具条就会跟着刷。
                            // 与「显示 P/D 速度」分工不同 —— 那个只在生成结束后给最终值。
                            if MiniCPMV47Const.liveTpsEnabled() {
                                let live = self?.mtmdWrapperExample?.livePerfDisplayString() ?? ""
                                latestCell.model?.speedLog = live.isEmpty ? nil : live
                            } else {
                                // 实时关：本轮先清空，等生成完成后由「显示 P/D 速度」填最终值。
                                latestCell.model?.speedLog = nil
                            }
                            // 流式期间也上 markdown（走 StreamingMarkdownRenderer 增量解析）。
                            // 生成完成时 $performanceLog 回调会用 streaming: false 再渲染一次，
                            // 给出精确的最终排版。
                            latestCell.bindTextWith(data: latestCell.model, streaming: true)

                            // 高度**只增不减**：markdown 在标记闭合的瞬间会缩短渲染宽度/高度
                            // （`**x**`→`x`、`### `→``、``` ``` `` 等），若让 cellHeight 跟着回缩，
                            // 配合下方「钉到底部」的滚动，整个输出区会每帧上下弹动。
                            // 这里取与已用高度的较大值消除回缩；完成时的全量渲染会精确收敛。
                            let measuredHeight = latestCell.heightFromRenderedContent(
                                viewWidth: self?.view.frame.width ?? 0)
                            latestCell.model?.cellHeight = max(
                                latestCell.model?.cellHeight ?? 0, measuredHeight)

                            self?.tableViewScrollToBottom(animated: false)
                        }
                        
                    }
                    
                } else {
                    
                    // cell 为空时
                    // 如果存在 live stream vc，则输出到 live stream 的 output 上
                    if let liveVC = self?.liveStreamVC {
                        
                        var formatedStr = receivedData
                        
                        // 替换 “\\n” 为 " "
                        formatedStr = formatedStr.replacingOccurrences(of: "\\n", with: "\n")
                        if !formatedStr.isEmpty {
                            liveVC.updateWithOutputLabel(str: formatedStr)
                        }
                        
                    }
                    
                }
                
            }
        
        // 订阅 performanceLog @Published 属性的变化
        perfLogSubscriber = mtmdWrapperExample?.$performanceLog
            .receive(on: DispatchQueue.main)   // 更新 UI 的相关操作切换到主线程
            .sink { [weak self] log in
                
                // 输出完成
                if !log.isEmpty {
                    self?.thinking = false
                    // 「最快」模式撑过了第一轮问答：清掉安全网标记（其它模型上没有 pending，空转）。
                    MiniCPM5_15B_A2_5BConst.markMmapLoadOk()
                    // 上下文窗口写满导致的停止：提示新建对话（不写进回答正文）
                    if self?.mtmdWrapperExample?.isContextFull == true {
                        self?.showErrorTips(L.Home.contextFull.loc, delay: 4)
                    }
                }
                
                // 同步给 live stream vc
                if let liveVC = self?.liveStreamVC {
                    if log.contains("Done") {
                        
                        self?.thinking = true
                        
                        Task {
                            // question gap
                            let retrievedDictionary = UserDefaults.standard.dictionary(forKey: "mb_ls_presets") as? [String: [String: String]]
                            
                            // 默认等 2 秒，再抽帧
                            var gap = 2000
                            
                            if let qgap = retrievedDictionary?["qgap"] {
                                let tmp = Int(qgap["qgap"] ?? "0") ?? 0
                                gap = tmp
                            }
                            
                            debugLog("-->> 提问间隔 = \(gap) 毫秒")
                            usleep(useconds_t(gap * 1000))
                            
                            // live stream 正式完成
                            liveVC.processing = false
                            
                            // 再同步把 thinking 关了
                            self?.thinking = false
                            
                            // live stream 正式重置 embed count 为 0
                            debugLog("-->> embed, 提问完成，embedCount 重置为 0.")
                            liveVC.embeddingCount = 0
                            
                            self?.mtmdWrapperExample?.outputText = ""
                            self?.mtmdWrapperExample?.performanceLog = ""
                            
                            let time = NSDate().timeIntervalSince1970
                            debugLog("-->> $performanceLog \(time) 输出完成。")
                        }
                        
                        // eat \n
                        if let outputString = liveVC.getOutputLabelString() {
                            var formatedStr = outputString
                            while formatedStr.hasSuffix("\n") == true {
                                formatedStr = String(formatedStr.dropLast())
                            }
                            if !formatedStr.isEmpty {
                                liveVC.updateWithOutputLabel(str: formatedStr)
                            }
                        }
                    }
                }
                
                
                if let c = self?.dataArray.count, c > 0 {
                    let lastModel = self?.dataArray[c - 1]
                    if lastModel?.role == "llm" {
                        // 多模态模型 更新性能日志
                        if !log.hasPrefix("Loaded model") {
                            lastModel?.performLog = log

                            if !log.isEmpty {
                                lastModel?.hasBottomToolbar = true
                                // 完成后回填最终值（「显示 P/D 速度」关着时返回空串，
                                // 这时**保留**流式期间写下的实时值，别把它清掉）。
                                if let final = self?.mtmdWrapperExample?.lastPerfDisplayString(), !final.isEmpty {
                                    lastModel?.speedLog = final
                                }
                                lastModel?.cellHeight = MBTextTableViewCell.calcCellHeight(data: lastModel, viewWidth: self?.view.frame.width ?? 0)
                            }

                            self?.reloadAndScrollToBottom()

                            if !log.isEmpty {
                                if let latestCell = self?.tableView.cellForRow(at: IndexPath(row: c - 1, section: 0)) as? MBTextTableViewCell {
                                    latestCell.bindTextWith(data: lastModel)
                                    latestCell.layoutIfNeeded()
                                }

                                self?.showFloatingActionViewWith(show: false)

                                self?.mtmdWrapperExample?.outputText = ""
                                self?.mtmdWrapperExample?.performanceLog = ""
                            }
                        }
                    }
                }
            }
        
    }
}
