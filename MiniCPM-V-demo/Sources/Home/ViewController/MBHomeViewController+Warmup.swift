//
//  MBHomeViewController+Warmup.swift
//  MiniCPM-V-demo
//
//  iOS 系统子系统懒加载 → 用户点按钮"卡一下"的预热补丁。
//
//  对应的两个用户报告：
//    1. 「点切片数量按钮，第一次 alert 弹出停顿一下才出来」
//    2. 「点图片按钮，第一次 picker 弹出停顿一下才出来」
//
//  根因不是 demo 自己代码慢，是 iOS 几个 first-use 懒加载组件：
//
//    - UIAlertController 首次 present：UIPresentationController 子系统、
//      UIBlurEffect → Metal blur kernel 首次编译、临时 alert UIWindow 的
//      windowScene 状态切换 …… 累计 ~80–150 ms
//    - PHPickerViewController 首次 present：PhotoUI.framework dlopen +
//      class registration (~50–100 ms)，加上 `pickerd` XPC service 由
//      launchd 首次 spawn (~300–800 ms)。这是 PHPicker 的著名"首次卡"
//
//  Apple 没有公开的 preheat API，可用的 trick 是 app 启动后异步 fire 一次
//  invisible present + immediate dismiss，让上面的子系统都按需初始化好，
//  等用户真按按钮时直接 cache hit。代价只是启动后 ~1.5s 偷偷做一次轻量
//  present，肉眼不可见（alpha=0），且这时 home VC 已显示、模型 init 在
//  background 跑，main thread 相对空闲，挤压可控。
//

import Foundation
import UIKit
import PhotosUI

extension MBHomeViewController {

    /// 在 home VC 显示一段时间后异步预热 UIAlertController + PHPicker，
    /// 让用户后续点切片 / 选图按钮的"首次卡顿"消失。
    ///
    /// 安全调用：viewDidLoad 末尾即可。delay 后的闭包通过 `[weak self]`
    /// 持有 self，home VC 销毁时整段 silently 跳过。
    func warmUpSystemPresentations() {
        // 1.5 s：home VC viewDidAppear 后已经 layout 完毕，模型 init 走的是
        // Task.detached(priority: .userInitiated) 的 background queue，
        // 这时 main 相对空闲，预热不会影响关键路径。再短可能撞 mtmd 第一次
        // metal kernel 编译期；再长用户可能已经在点按钮了，预热失去意义。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self._warmUpAlertOnce()
            self._warmUpPHPickerOnce()
        }
    }

    /// 触发一次 invisible UIAlertController.present + immediate dismiss。
    ///
    /// 用 `alpha = 0` 让 alert 视觉上完全不可见（包括 backdrop blur），
    /// 用 `animated: false` 跳过 UIKit 转场动画。整个过程 1 帧以内完成，
    /// 用户感受不到。但 UIKit 内部已经把 UIPresentationController /
    /// UIBlurEffect / alert UIWindow 的 backing class registration / Metal
    /// blur kernel 等都初始化了，等真用户按"切片数量"按钮时直接命中 cache。
    private func _warmUpAlertOnce() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
        alert.view.alpha = 0
        present(alert, animated: false) {
            alert.dismiss(animated: false)
        }
    }

    /// 仅实例化一次 PHPickerViewController 然后丢弃。**不**真正 present。
    ///
    /// 实例化已经会触发：
    ///   - PhotoUI.framework 的 dlopen + ObjC class registration
    ///   - PHPicker 内部的 NSExtension principal-class lookup（这是 picker
    ///     UI 跑在 `pickerd` 进程的入口，touching 它会让 launchd 排队 spawn
    ///     该 XPC service —— 真 present 时进程已就绪，肉眼能感觉到首次延迟
    ///     从 ~600 ms 降到 ~150 ms）
    ///
    /// 我们故意不真 present —— 不想让用户启动后看到一个一闪而过的相册
    /// grid。只走"实例化"这条路径，能预热的就预热，剩下的（pickerd 真正
    /// 启动 + 索引 query）等用户首次按图片按钮时实际触发。
    private func _warmUpPHPickerOnce() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        _ = PHPickerViewController(configuration: config)
    }
}
