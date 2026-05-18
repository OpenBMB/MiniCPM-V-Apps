//
//  MBTutorialModel.swift
//  MiniCPM-V-demo
//
//  教程页面的卡片数据
//

import Foundation
import UIKit

struct MBTutorialStep {
    /// 步骤编号显示，例如 "1"、"2"
    let index: String
    /// 卡片标题
    let title: String
    /// 卡片正文（支持多段，用 \n\n 分段）
    let body: String
    /// SF Symbol 名称（顶部圆形图标）
    let symbolName: String
    /// 圆形图标背景色
    let symbolBgColor: UIColor
    /// 截图素材名（Assets 中的 imageset 名称，未提供则显示占位）
    let screenshotAsset: String?
    /// 占位提示文字（screenshotAsset == nil 或资源不存在时显示）
    let placeholderHint: String
}

enum MBTutorialContent {

    /// Async prewarm of the tutorial step screenshots so the first push of
    /// MBTutorialViewController doesn't synchronously decode 4 × ~1-3 MiB
    /// PNGs in the middle of the navigation transition (which the user
    /// feels as a 200-400 ms "stutter" when they tap the tutorial button).
    ///
    /// Safe + cheap to call from anywhere — UIImage(named:) caches are
    /// thread-safe for read, and we just discard the returned UIImage.
    /// Recommended call site: MBHomeViewController.viewDidLoad once.
    static func prewarmScreenshotsInBackground() {
        let assetNames = steps().compactMap { $0.screenshotAsset }
        DispatchQueue.global(qos: .utility).async {
            for name in assetNames {
                _ = UIImage(named: name)
            }
        }
    }


    static func steps() -> [MBTutorialStep] {
        return [
            MBTutorialStep(
                index: "1",
                title: "下载模型",
                body: """
                首次使用需要下载模型文件，整体约 2.5 GB，建议在 Wi-Fi 环境下进行。

                进入「设置 → 模型管理 → MiniCPM-V 4.6」，点击「一键下载」按钮，三个文件会并行下载（主模型、视觉编码器、ANE 加速模块）。下载完成后可在该页面看到「已下载」状态。
                """,
                symbolName: "icloud.and.arrow.down",
                symbolBgColor: UIColor.mb_color(with: "#007AFF") ?? .systemBlue,
                screenshotAsset: "tutorial_step1_download",
                placeholderHint: "下载模型示意图"
            ),

            MBTutorialStep(
                index: "2",
                title: "选择并加载模型",
                body: """
                下载完成后，回到模型管理页，点击 MiniCPM-V 4.6 卡片底部的「使用此模型」。

                等待加载完成（首次加载需几秒到十几秒，会把模型读入内存），加载成功后会自动返回主界面。
                """,
                symbolName: "checkmark.seal.fill",
                symbolBgColor: UIColor.mb_color(with: "#34C759") ?? .systemGreen,
                screenshotAsset: "tutorial_step2_load",
                placeholderHint: "选择模型示意图"
            ),

            MBTutorialStep(
                index: "3",
                title: "文字 / 图片提问",
                body: """
                在底部输入框中输入问题后点击发送按钮即可对话。

                如需让模型识图，先点击输入框左侧的「图片」按钮选择一张图片，再输入提问内容（例如「请描述这张图片」）。模型会同时理解图像与文字。
                """,
                symbolName: "bubble.left.and.bubble.right.fill",
                symbolBgColor: UIColor.mb_color(with: "#FF9500") ?? .systemOrange,
                screenshotAsset: "tutorial_step3_chat",
                placeholderHint: "对话与识图示意图"
            ),

            MBTutorialStep(
                index: "4",
                title: "多轮对话与清空",
                body: """
                同一个会话内，模型会记住前几轮的内容，可以基于上下文继续追问。

                点击右上角的垃圾桶图标可以清空当前对话，回到全新的会话状态（也会释放上下文显存）。
                """,
                symbolName: "trash.fill",
                symbolBgColor: UIColor.mb_color(with: "#FF3B30") ?? .systemRed,
                screenshotAsset: "tutorial_step4_reset",
                placeholderHint: "清空对话示意图"
            )
        ]
    }
}
