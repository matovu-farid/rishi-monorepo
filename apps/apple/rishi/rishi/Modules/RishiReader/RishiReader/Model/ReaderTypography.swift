import Foundation

/// Composite of all per-book typography settings persisted via
/// ``ReaderSettingsStore``. Wraps font family + font size + line height
/// so the picker UI and the EPUB view-model can pass a single value
/// through the store API.
public struct ReaderTypography: Codable, Hashable, Sendable {
    public var fontFamily: ReaderFontFamily
    public var fontSize: ReaderFontSize
    public var lineHeight: ReaderLineHeight

    public init(
        fontFamily: ReaderFontFamily = .default,
        fontSize: ReaderFontSize = .default,
        lineHeight: ReaderLineHeight = .default
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    public static let `default`: ReaderTypography = ReaderTypography()
}
