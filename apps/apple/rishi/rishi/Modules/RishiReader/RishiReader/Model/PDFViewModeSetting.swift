import Foundation

/// User-facing PDF view-mode preference (Mac only). Raw String values are
/// persisted via the reader-defaults layer (Wave 4) — DO NOT rename without a
/// migration. Resolves to an effective ``PDFReaderLayoutMode`` via
/// ``PDFReaderLayoutResolver/resolve(setting:isFullScreen:availableSize:minPageWidth:gutter:)``.
public enum PDFViewModeSetting: String, Codable, CaseIterable, Sendable, Hashable {
    case automatic
    case singlePage
    case continuous
    case twoPage

    /// Default value for a freshly opened book / first run.
    public static let `default`: PDFViewModeSetting = .automatic

    /// Human-readable label for the Settings picker.
    public var displayName: String {
        switch self {
        case .automatic:  return "Automatic"
        case .singlePage: return "Single Page"
        case .continuous: return "Continuous"
        case .twoPage:    return "Two Page"
        }
    }
}
