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

        // 改名前的 OCR 权重不能被当前代码加载，启动时清掉。
        MiniCPMModelConst.removeStaleOcrFiles()

        // CoreML ViT bootstrap disabled — OCR uses llama.cpp Metal backend exclusively.
        // DispatchQueue.global(qos: .utility).async {
        //     MiniCPMV46CoreMLBootstrap.installBundledModelIntoDocumentsIfNeeded()
        // }
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
