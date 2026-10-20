//
//  AppDelegate.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/6.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 以下三项都只允许在进程启动时跑一次。
        if ProcessInfo.processInfo.arguments.contains("-moeCacheWindowReset") {
            print("[MODEL] -moeCacheWindowReset：已清除保存的专家缓存 c")
            MiniCPMV47Const.resetCacheWindowC()
        }
        MiniCPMV47Const.applyCacheWindowCrashRecoveryIfNeeded()
        MiniCPMV47Const.migrateDsparkDefaultOffIfNeeded()

        // c 的默认值按设备内存分档（仅 V47 用 decode window）。
        if UserDefaults.standard.string(forKey: "current_selected_model") == MiniCPMV47Const.userDefaultsKey {
            MiniCPMV47Const.seedCacheWindowDefaultIfNeeded()
        }

        // 跑批模式：整进程保持亮屏，包括「跑完后的待机段」。
        // 只在 Runner 里设不够 —— 模型加载那几十秒没人碰屏幕，照样会先息屏，
        // 后续推理虽然把标志设回来，屏幕也不会自己亮，功率口径就废了。
        if ProcessInfo.processInfo.arguments.contains("-bench") {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        DispatchQueue.global(qos: .utility).async {
            MiniCPMV46CoreMLBootstrap.installBundledModelIntoDocumentsIfNeeded()
        }

        // 跑批数据集：把 bundle 里的 track 铺到 Documents/benchmark/<track>/。
        // 必须在任何读取之前完成，所以放后台队列、并用戳记做幂等（已铺过就只读一次目录）。
        DispatchQueue.global(qos: .utility).async {
            do {
                let summary = try BenchmarkSampleDataset.installBundledDatasetsIfNeeded()
                print("[DATASET] installed: \(summary) (active=\(BenchmarkCaseStore.activeTrack()))")
            } catch {
                print("[DATASET] install failed: \(error)")
            }
        }
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}
