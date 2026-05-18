//
//  MBHomeViewController+NavBarEvent.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/7/9.
//

import Foundation
import UIKit

/// Home 页面顶导按钮事件
extension MBHomeViewController {
    
    // MARK:  - 顶导 点击 事件

    /// 去到模型设置页
    @objc func settingButtonTapped() {

        // 新设置
        if let mtmdWrapperExample = mtmdWrapperExample {
            let settingsVC = MBSettingsViewController(with: mtmdWrapperExample)
            
            // 设置模型更新回调
            settingsVC.updateUsingModeltype = { newModelType in
                // 在这里处理模型类型更新
                print("模型已更新为: \(newModelType)")
            }
            
            // 推送到导航控制器
            self.navigationController?.pushViewController(settingsVC, animated: true)
        }
    }
    
    /// 跳转教程页
    @objc func tutorialButtonTapped() {
        let vc = MBTutorialViewController()
        self.navigationController?.pushViewController(vc, animated: true)
    }

    /// 顶导切图设置按钮 → 弹出滑条选择切图档位 (1..9)
    @objc func imageSliceButtonTapped() {
        let initial = ImageSliceSetting.current
        MBImageSliceSettingAlert.present(from: self, initialValue: initial) { [weak self] chosen in
            guard let self = self else { return }
            // mtmdWrapperExample 持久化新值并 live 推到 mtmd_context（如果已 init）
            self.mtmdWrapperExample?.updateImageMaxSliceNums(chosen)

            let loaded = self.mtmdWrapperExample?.multiModelLoadingSuccess ?? false
            let message = loaded
                ? "图片切片数已切换为 \(chosen)"
                : "已保存切片数 \(chosen)，下次加载模型时生效"
            let hud = MBHUD.showAdded(to: self.view, animated: true)
            hud.mode = .text
            hud.label.text = message
            hud.hide(animated: true, afterDelay: 2)
        }
    }

    /// delete nav item clicked
    @objc func deleteButtonTapped() {

        if thinking {
            self.showErrorTips("处理中，请稍等")
            return
        }

        let alertController = UIAlertController(title: "是否清除对话记录",
                                                message: "清除后对话记录无法恢复，是否确认清除对话记录？",
                                                preferredStyle: .alert)
        
        let okayAction = UIAlertAction(title: "删除",
                                       style: .destructive) { [weak self] (action) in
            // 重置所有标记位
            self?.dataArray.removeAll()
            self?.tableView.reloadData()
            self?.textInputView.text = ""
            self?.outputImageView.image = nil
            self?.outputImageURL = nil
            self?.hasImageAndTextConversation = false
            self?.currentUsingModelType = .Unknown
            self?.thinking = false
            
            self?.cachedImageEmbeddingPerfLog.removeAll()
            self?.cachedVideoURLs.removeAll()
            
            Task {
                // 重置多图模型加载状态
                await self?.updateImageLoadedStatus(false)
            }
            
            // 重置 llama.cpp 状态
            Task {
                await self?.mtmdWrapperExample?.reset()
                self?.checkMultiModelLoadStatusAndLoadIt()
            }
        }
        
        let cancelAction = UIAlertAction(title: "取消",
                                         style: .cancel,
                                         handler: nil)
        
        alertController.addAction(okayAction)
        alertController.addAction(cancelAction)
        
        present(alertController, animated: true, completion: nil)
    }
    
}
