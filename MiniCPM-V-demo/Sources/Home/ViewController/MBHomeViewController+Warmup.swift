//
//  MBHomeViewController+Warmup.swift
//  MiniCPM-V-demo
//
//  iOS 系统子系统懒加载 → 用户点按钮"卡一下"的预热补丁。
//
//  对应的用户报告：
//    「点切片数量按钮，第一次 alert 弹出停顿一下才出来」
//
//  根因不是 demo 自己代码慢，是 iOS 几个 first-use 懒加载组件：
//
//    - UIAlertController 首次 present：UIPresentationController 子系统、
//      UIBlurEffect → Metal blur kernel 首次编译、临时 alert UIWindow 的
//      windowScene 状态切换 …… 累计 ~80–150 ms
//
//  注：选图走 HXPhotoPicker（非系统 PHPicker），没有 PHPicker 那条
//  `pickerd` XPC service 首次 spawn 的开销，故这里不再为 picker 做预热。
//
//  Apple 没有公开的 preheat API，可用的 trick 是 app 启动后异步 fire 一次
//  invisible present + immediate dismiss，让上面的子系统都按需初始化好，
//  等用户真按按钮时直接 cache hit。代价只是启动后 ~1.5s 偷偷做一次轻量
//  present，肉眼不可见（alpha=0），且这时 home VC 已显示、模型 init 在
//  background 跑，main thread 相对空闲，挤压可控。
//

import Foundation
import UIKit

extension MBHomeViewController {

    /// 在 home VC 显示一段时间后异步预热 UIAlertController，
    /// 让用户后续点切片按钮的"首次卡顿"消失。
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
            self._warmUpImagePickerOnce()
            self._warmUpKeyboardOnce()
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
        // "Designed for iPad" on Mac maps UIAlertController onto a native
        // macOS panel. That panel ignores `alert.view.alpha = 0`, so the
        // dummy title/action (both ".") show up as two black dots in an
        // empty dialog. Slice-number alerts are chat-only; skip warmup.
        if ProcessInfo.processInfo.isiOSAppOnMac { return }
        // Presenting from home while OCR/TTS covers it can leave the alert
        // stranded on top of the child UI even on iPhone.
        if ocrViewController?.view.superview != nil { return }
        if ttsViewController?.view.superview != nil { return }

        // iOS 26+ 在 present 时 assert UIAlertController 必须有可显示内容，
        // 否则抛 `NSInternalInconsistencyException: UIAlertController must
        // have a title, a message or an action to display`，未被 catch 会
        // 走到 llama.cpp 注册的 std::terminate_handler 直接 abort，启动闪退
        // （见 issue OpenBMB/MiniCPM-V-Apps#14, iOS 26.5 模拟器复现）。
        // iOS 25 及以前给一个空格 message 就能蒙混过去，iOS 26 SDK 在校验前
        // 做了 whitespace trim，单空格被视为空。这里给一个非空 title + 一个
        // dummy action 双保险，alpha=0 + animated:false + 立即 dismiss，
        // 用户依然完全无感。
        let alert = UIAlertController(title: ".", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ".", style: .cancel))
        alert.view.alpha = 0
        present(alert, animated: false) {
            alert.dismiss(animated: false)
        }
    }

    /// 仅实例化一次 UIImagePickerController 然后丢弃。**不**真正 present。
    ///
    /// OCR 页面使用 UIImagePickerController（而非 PHPicker），首次
    /// `UIImagePickerController()` alloc 会触发 PhotoLibrary 子系统的
    /// dlopen + class registration + XPC service 连接，累计约 1-1.5 s。
    /// 这里提前跑一次 alloc，等用户真点相机/图库按钮时，init 路径已是
    /// 纯 cache hit（~ms）。
    private func _warmUpImagePickerOnce() {
        _ = UIImagePickerController()
    }

    /// 触发系统键盘 extension 的首次 spawn —— 尤其针对装了第三方输入法
    /// （讯飞 / 搜狗 / 百度 等）的用户。
    ///
    /// 第三方输入法在 iOS 上是独立的 app extension 沙箱进程，首次被唤起需要：
    ///   1. launchd spawn extension process（~200-500 ms）
    ///   2. dyld 链接 + framework 加载
    ///   3. 输入法自身的词库 / AI 候选模型加载（讯飞 ~1-3 s）
    ///   4. RunningBoard 协商生命周期（讯飞缺 entitlement 时还会 retry）
    ///
    /// 同时还会附带 iOS 自己的键盘子系统懒加载：
    ///   - UITextInput / UIKeyboard 单例的 lazy init
    ///   - 候选词 accumulator (`Received external candidate resultset` 那条 log)
    ///   - 系统手势识别器 `System gesture gate` 注册
    ///
    /// 不预热时，用户进入 home VC 后第一次点输入框会卡 2-5 s 等键盘弹出，期间
    /// `<0x...> Gesture: System gesture gate timed out.` 是典型 log 信号。
    /// 我们用一个屏幕外 alpha=0 的 UITextField 偷偷 becomeFirstResponder + 立刻
    /// resign，把整条冷启动链在 home VC 显示 1.5s 后 background 跑掉。等用户
    /// 真点输入框时键盘 extension 已 ready，bring-up 路径全是 cache hit。
    ///
    /// 安全保护：
    ///   - 仅在用户的真实输入框还没获焦时才执行，避免抢走正在用的键盘
    ///   - 临时 textField 加在屏幕外 (-1000,-1000) + alpha=0，肉眼不可见
    ///   - resign 后异步从父视图移除，确保不残留
    private func _warmUpKeyboardOnce() {
        if textInputView.isFirstResponder { return }

        let probe = UITextField(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        probe.alpha = 0
        probe.autocorrectionType = .no
        probe.spellCheckingType = .no
        view.addSubview(probe)

        // becomeFirstResponder 立刻触发系统去唤起当前默认键盘 extension。
        _ = probe.becomeFirstResponder()

        // 0.05 s 已足够让系统把 keyboard extension 的 spawn 请求 enqueue；
        // extension 实际的 process spawn / dlopen 仍在 background 继续，
        // 但 main thread 已交还。再延一帧 resignFirstResponder + 移除节点。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            probe.resignFirstResponder()
            probe.removeFromSuperview()
        }
    }
}
