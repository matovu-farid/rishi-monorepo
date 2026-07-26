import Foundation

/// User-selectable EPUB line height multiplier. Clamped to [1.0 ... 2.0].
public struct ReaderLineHeight: Codable, Hashable, Sendable {
    public static let min: Double = 1.0
    public static let max: Double = 2.0

    public let multiplier: Double

    public init(multiplier: Double) {
        self.multiplier = Swift.min(Swift.max(multiplier, Self.min), Self.max)
    }

    public static let `default`: ReaderLineHeight = ReaderLineHeight(multiplier: 1.4)
}
