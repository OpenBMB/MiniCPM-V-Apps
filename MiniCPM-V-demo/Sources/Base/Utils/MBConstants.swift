//
//  MBConstants.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/7/16.
//

import Foundation
import UIKit

/// Window and View 常用常量
class MBConstants {

    static let shared = MBConstants()
    
    // Cache the result at startup
    let isPhoneXSeries: Bool = {
        if #available(iOS 13.0, *) {
            let windows = UIApplication
                .shared
                .connectedScenes
                .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                .last { $0.isKeyWindow }
            if let window = windows {
                return window.safeAreaInsets.bottom > 0
            }
        } else {
            if let window = UIApplication.shared.delegate?.window, 
                let safeWindow = window {
                return safeWindow.safeAreaInsets.bottom > 0
            }
        }
        return false
    }()
    
    // All constants
    let kNavBarContentHeight: CGFloat = 44.0
    var kStatusBarHeight: CGFloat { isPhoneXSeries ? 44.0 : 20.0 }
    var kNavBarHeight: CGFloat { isPhoneXSeries ? 88.0 : 64.0 }
    var kTabBarHeight: CGFloat { isPhoneXSeries ? 83.0 : 49.0 }
    var kBottomSafeHeight: CGFloat { isPhoneXSeries ? 34 : 0 }
}

/// Cross-VC notifications.  Keeping the names here so we don't grep for
/// stringly-typed identifiers across the project later.
extension Notification.Name {
    /// Posted by V2.6 / V4 / V4.6 model-detail VCs after the user taps
    /// "使用该模型" and the UserDefault `current_selected_model` has been
    /// updated.  MBHomeViewController listens for this and forces a
    /// reset + reload of the MTMD wrapper so the next image / chat turn
    /// runs on the freshly-selected model — without this, the home VC's
    /// one-shot `didStartInitialModelLoad` flag swallows the change and
    /// the user sees `[UI]addImage skip: model not loaded yet`.
    static let mbModelSelectionChanged = Notification.Name("com.mb.minicpmv.modelSelectionChanged")

    /// Posted by the settings page when the "show P/D speed" switch is toggled.
    /// MBHomeViewController listens and re-derives the tool-bar speed text on the
    /// already-rendered replies, so the switch takes effect immediately instead of
    /// only on the next generation (the user flips this while recording).
    static let mbPerfSpeedVisibilityChanged = Notification.Name("com.mb.minicpmv.perfSpeedVisibilityChanged")

    /// Posted when the "OCR live speed" switch is toggled, so an in-flight OCR page
    /// hides or shows the readout without waiting for the next token.
    static let ocrLiveTpsChanged = Notification.Name("com.mb.minicpmv.ocrLiveTpsChanged")
}
