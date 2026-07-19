import Foundation

/// User-selectable reader theme. Raw String values are persisted
/// (per-book) via ``ReaderSettingsStore`` — DO NOT rename without a
/// migration. Sync (Phase 7) round-trips the same raw String.
public enum ReaderTheme: String, Codable, CaseIterable, Sendable, Hashable {
    case matchDevice
    case light
    case sepia
    case dark

    /// Default theme for a freshly opened book.
    public static let `default`: ReaderTheme = .matchDevice

    public func resolved(isDark: Bool) -> ReaderTheme {
        switch self {
        case .matchDevice: return isDark ? .dark : .light
        case .light, .sepia, .dark: return self
        }
    }
}
