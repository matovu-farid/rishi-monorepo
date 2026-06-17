//
//  SettingsMacWindowSizing.swift
//  rishi
//
//  Phase 32 Plan 32-03 — imperative Mac-Catalyst-gated helper that fixes the
//  dedicated Settings window's size and title. Mirrors the proven
//  `connectedScenes -> UIWindowScene.sizeRestrictions` idiom from
//  RishiReader's `PDFMacWindowSizing` (Pitfall 9: `sizeRestrictions` is nil on
//  some scene configurations — guard it).
//
//  Fixed-size prefs window (min == max) per RESEARCH §A5 / HIG fixed-size
//  settings convention, reusing the tested `SettingsWindowSizing` core from
//  Plan 32-01. Catalyst-only: iOS never opens the Settings window.
//

#if targetEnvironment(macCatalyst)

import UIKit
import CoreGraphics

/// Applies the fixed 720x640 size and "Settings" title to whichever live
/// `UIWindowScene` currently hosts the Settings window. Called from
/// `SettingsWindowRoot.onAppear` once the scene is on screen.
@MainActor
enum SettingsMacWindowSizing {

    static func apply() {
        let size = SettingsWindowSizing.fixedSettingsSize
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  let restrictions = windowScene.sizeRestrictions else { continue }
            // Fixed-size: min == max so the prefs window cannot be resized,
            // matching the macOS settings convention (RESEARCH §A5 / Open Q4).
            restrictions.minimumSize = size
            restrictions.maximumSize = size
            windowScene.title = "Settings"
        }
    }
}

#endif
