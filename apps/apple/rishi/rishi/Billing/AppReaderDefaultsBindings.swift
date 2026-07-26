import Foundation
import Observation


import SwiftUI

@MainActor
@Observable
final class AppReaderDefaults {

    private static let themeKey = "reader.defaults.theme"
    private static let fontKey = "reader.defaults.fontFamily"

    private static let pdfViewModeKey = "reader.defaults.pdfViewMode"

    private static let autoSyncKey = "reader.defaults.autoSync"
    private static let voiceLanguageKey = "voice.language"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var theme: ReaderTheme {
        get {
            guard let raw = defaults.string(forKey: Self.themeKey),
                let theme = ReaderTheme(rawValue: raw)
            else { return .default }
            return theme
        }
        set { defaults.set(newValue.rawValue, forKey: Self.themeKey) }
    }

    var fontFamily: ReaderFontFamily {
        get {
            guard let raw = defaults.string(forKey: Self.fontKey),
                let font = ReaderFontFamily(rawValue: raw)
            else { return .system }
            return font
        }
        set { defaults.set(newValue.rawValue, forKey: Self.fontKey) }
    }

    var pdfViewMode: PDFViewModeSetting {
        get {
            guard let raw = defaults.string(forKey: Self.pdfViewModeKey),
                let mode = PDFViewModeSetting(rawValue: raw)
            else { return .continuous }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Self.pdfViewModeKey) }
    }

    /// Distinguishes a fresh install from a user who explicitly selected
    /// Automatic. This keeps the new default from overwriting an existing
    /// preference.
    var hasSavedPDFViewMode: Bool {
        defaults.object(forKey: Self.pdfViewModeKey) != nil
    }

    var autoSync: Bool {
        get {
            guard defaults.object(forKey: Self.autoSyncKey) != nil else {
                return true
            }
            return defaults.bool(forKey: Self.autoSyncKey)
        }
        set { defaults.set(newValue, forKey: Self.autoSyncKey) }
    }

    var voiceLanguage: VoiceLanguageOption {
        get {
            guard let raw = defaults.string(forKey: Self.voiceLanguageKey),
                let language = VoiceLanguageOption(rawValue: raw)
            else { return .english }
            return language
        }
        set { defaults.set(newValue.rawValue, forKey: Self.voiceLanguageKey) }
    }

}
