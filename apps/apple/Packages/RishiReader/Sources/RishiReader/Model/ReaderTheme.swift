import Foundation

/// User-selectable reader theme. Raw String values are persisted
/// (per-book) via ``ReaderSettingsStore`` — DO NOT rename without a
/// migration. Sync (Phase 7) round-trips the same raw String.
public enum ReaderTheme: String, Codable, CaseIterable, Sendable, Hashable {
    case light
    case sepia
    case dark

    /// Default theme for a freshly opened book.
    public static let `default`: ReaderTheme = .light
}
