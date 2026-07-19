#if canImport(UIKit)
import Foundation
import ReadiumNavigator
import ReadiumShared
import RishiLogging

/// Our spread-mode enum. ``EPUBSpreadModifier`` (Task 5) picks the
/// appropriate mode for the current device + orientation, and the
/// screen forwards it through ``EPUBPreferencesBridge`` to Readium.
public enum EPUBSpreadMode: String, Sendable, Equatable {
    /// Always single column (iPhone, iPad portrait).
    case single
    /// Always two-column spread (forces it on regardless of device).
    case double
    /// Let Readium decide based on viewport (iPad landscape → 2 columns).
    case auto
}

/// Translates our `ReaderTypography` + `ReaderTheme` + ``EPUBSpreadMode``
/// into Readium 3.9's `EPUBPreferences` and submits them to the navigator.
///
/// Bundling the translation behind a single static call keeps the Readium
/// API surface confined to this file — a future Readium API rename only
/// touches one place. Verified against
/// `.build/checkouts/swift-toolkit/Sources/Navigator/EPUB/Preferences/EPUBPreferences.swift`
/// in Readium 3.9: fields are `fontFamily: FontFamily?`, `fontSize: Double?`
/// (multiplier of a 16pt baseline), `lineHeight: Double?`, `theme: Theme?`,
/// `spread: Spread?`.
public enum EPUBPreferencesBridge {

    /// 16pt CSS baseline. Readium's `fontSize` is a multiplier of this
    /// baseline (1.0 == 16pt, 1.25 == 20pt, etc).
    static let cssBaselinePoints: Double = 16.0

    public static func apply(
        typography: ReaderTypography,
        theme: ReaderTheme,
        spread: EPUBSpreadMode,
        to navigator: EPUBNavigatorViewController
    ) {
        let prefs = EPUBPreferences(
            fontFamily: readiumFontFamily(for: typography.fontFamily),
            fontSize: typography.fontSize.points / cssBaselinePoints,
            lineHeight: typography.lineHeight.multiplier,
            spread: readiumSpread(for: spread),
            theme: readiumTheme(for: theme)
        )
        navigator.submitPreferences(prefs)
        Log.reader.debug(
            "Applied EPUB preferences: font=\(typography.fontFamily.rawValue, privacy: .public) size=\(typography.fontSize.points, privacy: .public)pt lh=\(typography.lineHeight.multiplier, privacy: .public) theme=\(theme.rawValue, privacy: .public) spread=\(spread.rawValue, privacy: .public)"
        )
    }

    // MARK: - Translation

    static func readiumFontFamily(for family: ReaderFontFamily) -> FontFamily {
        switch family {
        case .system:   return FontFamily(rawValue: "-apple-system")
        case .serif:    return .serif
        case .sans:     return .sansSerif
        case .dyslexic: return .openDyslexic
        }
    }

    static func readiumTheme(for theme: ReaderTheme) -> ReadiumNavigator.Theme {
        switch theme {
        case .matchDevice: return .light // callers must pass resolved
        case .light: return .light
        case .sepia: return .sepia
        case .dark:  return .dark
        }
    }

    static func readiumSpread(for spread: EPUBSpreadMode) -> Spread {
        switch spread {
        case .single: return .never
        case .double: return .always
        case .auto:   return .auto
        }
    }
}
#endif
