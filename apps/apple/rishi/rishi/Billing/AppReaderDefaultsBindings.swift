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
}
