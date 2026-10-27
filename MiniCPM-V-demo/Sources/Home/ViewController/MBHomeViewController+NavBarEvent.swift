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
                ? String(format: L.Home.sliceChangedNowFormat.loc, "\(chosen)")
                : String(format: L.Home.sliceSavedNextLoadFormat.loc, "\(chosen)")
            let hud = MBHUD.showAdded(to: self.view, animated: true)
            hud.mode = .text
            hud.label.text = message
            hud.hide(animated: true, afterDelay: 2)
        }
    }

    /// delete nav item clicked
    @objc func deleteButtonTapped() {

        let current = UserDefaults.standard.string(forKey: "current_selected_model") ?? ""
        if current == "OcrModel" {
            resetOcrMode()
            return
        }
        if current == "Voxcpm2Model" {
            resetTtsMode()
            return
        }

        if thinking {
            self.showErrorTips(L.Home.tipProcessingWait.loc)
            return
        }

        let alertController = UIAlertController(title: L.Home.clearChatTitle.loc,
                                                message: L.Home.clearChatMessage.loc,
                                                preferredStyle: .alert)
        
        let okayAction = UIAlertAction(title: L.Common.delete.loc,
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
        
        let cancelAction = UIAlertAction(title: L.Common.cancel.loc,
                                         style: .cancel,
                                         handler: nil)
        
        alertController.addAction(okayAction)
        alertController.addAction(cancelAction)
        
        present(alertController, animated: true, completion: nil)
    }

    /// Reset TTS mode: clear UI, destroy + reload engine
    private func resetTtsMode() {
        let alert = UIAlertController(
            title: "清空内容",
            message: "将清除当前文本和参考音频，并重新加载模型，是否继续？",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.Common.delete.loc, style: .destructive) { [weak self] _ in
            // Destroy TTS engine
            let engine = TtsEngine.shared
            engine.destroy()

            // Clear TTS UI via the child VC
            if let ttsVC = self?.ttsViewController {
                ttsVC.resetAllContent()
            }

            // Reload model
            let hud = MBHUD.showAdded(to: self?.view ?? UIView(), animated: true)
            hud.label.text = L.Common.reloading.loc
            Task {
                let ok = await engine.loadModel()
                DispatchQueue.main.async {
                    hud.hide(animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))
        present(alert, animated: true)
    }

    private func resetOcrMode() {
        let alert = UIAlertController(
            title: L.Ocr.clearTitle.loc,
            message: L.Ocr.clearMessage.loc,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.Common.delete.loc, style: .destructive) { [weak self] _ in
            let engine = OcrEngine.shared
            engine.destroy()

            if let ocrVC = self?.ocrViewController {
                ocrVC.resetAllContent()
            }

            let hud = MBHUD.showAdded(to: self?.view ?? UIView(), animated: true)
            hud.label.text = L.Common.reloading.loc
            Task {
                await engine.loadModels()
                DispatchQueue.main.async {
                    hud.hide(animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: L.Common.cancel.loc, style: .cancel))
        present(alert, animated: true)
    }
}
