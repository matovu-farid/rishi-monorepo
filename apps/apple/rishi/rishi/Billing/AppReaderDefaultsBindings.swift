//
//  AppReaderDefaultsBindings.swift
//  rishi
//
//  Phase 11 Plan 11-06 — app-wide reader defaults persisted under
//  "reader.defaults.theme" / "reader.defaults.fontFamily". Per-book
//  overrides live in `ReaderSettingsStore` (Phase 5/6); these defaults
//  drive the brand-new Reader Defaults section in `SettingsScreen`.
//
//  This is an `@Observable` class so the SwiftUI `Binding` wired into
//  `SettingsScreen` triggers a redraw when the picker changes.
//

import Foundation
import SwiftUI
import RishiReader

/// App-wide reader defaults (SET-01 Reader section). Persisted in
/// `UserDefaults.standard` so the values survive relaunch. The reader phase
/// reads per-book values first and falls back to these on first-open.
@MainActor
@Observable
final class AppReaderDefaults {

    private static let themeKey = "reader.defaults.theme"
    private static let fontKey  = "reader.defaults.fontFamily"
    // Phase 31 plan 31-04 — Mac-only PDF view-mode preference. The Settings
    // picker (RishiSettings.PDFViewModeSection) writes this; PDFReaderScreen
    // (via PDFReaderDestination) reads the live @Observable value so a change
    // applies to an open PDF without reopening. Default `.automatic` (LOCKED).
    private static let pdfViewModeKey = "reader.defaults.pdfViewMode"
    // Phase 33 plan 33-01 — NEW persisted Auto Sync flag. Gates the automatic
    // sync triggers (BGTask, silent push, shell-appearance kick); the manual
    // "Sync Now" path ignores it. Default ON (see `autoSync` below).
    private static let autoSyncKey = "reader.defaults.autoSync"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var theme: ReaderTheme {
        get {
            guard let raw = defaults.string(forKey: Self.themeKey),
                  let theme = ReaderTheme(rawValue: raw) else { return .light }
            return theme
        }
        set { defaults.set(newValue.rawValue, forKey: Self.themeKey) }
    }

    var fontFamily: ReaderFontFamily {
        get {
            guard let raw = defaults.string(forKey: Self.fontKey),
                  let font = ReaderFontFamily(rawValue: raw) else { return .system }
            return font
        }
        set { defaults.set(newValue.rawValue, forKey: Self.fontKey) }
    }

    /// Mac-only PDF view-mode preference. Mirrors `theme`: persisted as a
    /// UserDefaults rawValue, falling back to `.automatic` when the key is
    /// absent (first run). No first-run write needed — the get default IS
    /// `.automatic` (LOCKED). The iOS reader never consults this value.
    var pdfViewMode: PDFViewModeSetting {
        get {
            guard let raw = defaults.string(forKey: Self.pdfViewModeKey),
                  let mode = PDFViewModeSetting(rawValue: raw) else { return .automatic }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Self.pdfViewModeKey) }
    }

    /// Phase 33 — gates automatic/background sync (BGTask, silent push,
    /// shell-appearance kick). Manual "Sync Now" ignores this flag. Default ON
    /// so existing users keep syncing on upgrade: an absent key means
    /// `object(forKey:)` is nil, so we return `true`. Using `bool(forKey:)`
    /// directly would wrongly default OFF for the absent case (Pitfall 4).
    var autoSync: Bool {
        get {
            guard defaults.object(forKey: Self.autoSyncKey) != nil else { return true }
            return defaults.bool(forKey: Self.autoSyncKey)
        }
        set { defaults.set(newValue, forKey: Self.autoSyncKey) }
    }
}
