import Foundation

/// User-selectable EPUB font family. Raw String values are persisted
/// per-book via ``ReaderSettingsStore`` and are the Phase 7 sync wire
/// format — DO NOT rename without a migration.
public enum ReaderFontFamily: String, Codable, CaseIterable, Sendable, Hashable {
    case system   // -apple-system / San Francisco
    case serif    // New York / Georgia fallback
    case sans     // Helvetica / Inter fallback
    case dyslexic // OpenDyslexic (bundled or system fallback)

    public static let `default`: ReaderFontFamily = .system

    /// CSS font-family value used by Readium's user-settings layer when
    /// applying the typeface in the navigator's WKWebView.
    public var cssFontFamily: String {
        switch self {
        case .system:   return "-apple-system"
        case .serif:    return "Georgia, 'New York', serif"
        case .sans:     return "Helvetica, Arial, sans-serif"
        case .dyslexic: return "'OpenDyslexic', sans-serif"
        }
    }

    /// Human label for the picker UI.
    public var label: String {
        switch self {
        case .system:   return "System"
        case .serif:    return "Serif"
        case .sans:     return "Sans"
        case .dyslexic: return "Dyslexic"
        }
    }
}
