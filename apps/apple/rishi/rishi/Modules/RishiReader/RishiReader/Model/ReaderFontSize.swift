import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// User-selectable EPUB body-text font size in points.
///
/// Clamped to [12 ... 32] pt. The default value derives from Dynamic
/// Type's `.body` preferred size (EPUB-09: respect Dynamic Type as the
/// starting size).
public struct ReaderFontSize: Codable, Hashable, Sendable {
    public static let min: Double = 12
    public static let max: Double = 32

    public let points: Double

    public init(points: Double) {
        self.points = Swift.min(Swift.max(points, Self.min), Self.max)
    }

    /// Default size — Dynamic Type's `.body` size on UIKit hosts,
    /// 17pt elsewhere (typical macOS default body size).
    public static var defaultPoints: Double {
        #if canImport(UIKit)
        return Double(UIFont.preferredFont(forTextStyle: .body).pointSize)
        #else
        return 17
        #endif
    }

    public static let `default`: ReaderFontSize = ReaderFontSize(points: defaultPoints)

    public static func clamped(_ v: Double) -> ReaderFontSize { ReaderFontSize(points: v) }
}
