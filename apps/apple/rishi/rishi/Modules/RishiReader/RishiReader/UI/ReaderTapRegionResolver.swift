import Foundation
import CoreGraphics

/// Pure decision: where on the page did the user tap?
///
/// Apple Books / iBooks tap-region contract:
/// - Left 25%  -> previous page
/// - Center 50% -> toggle chrome (inclusive on both 0.25 and 0.75 boundaries
///   so a tap exactly on the seam shows chrome rather than turning a page —
///   ambiguity defaults to the safer "show chrome" outcome).
/// - Right 25% -> next page
/// - When page navigation is disabled, the left/right regions are ignored.
///
/// The resolver is pure / `Sendable` / horizontal-only — vertical y does
/// not change the decision. Degenerate zero-width sizes return
/// `.toggleChrome` to avoid div-by-zero arithmetic and keep the safer
/// outcome.
public struct ReaderTapRegionResolver: Sendable, Equatable {

    public enum Decision: Sendable, Equatable {
        case previousPage
        case toggleChrome
        case nextPage
        case ignored
    }

    public init() {}

    public func decide(
        at point: CGPoint,
        in size: CGSize,
        allowsPageNavigation: Bool = true
    ) -> Decision {
        guard size.width > 0 else { return .toggleChrome }
        let leadingEdge = size.width * 0.25
        let trailingEdge = size.width * 0.75
        if point.x < leadingEdge {
            return allowsPageNavigation ? .previousPage : .ignored
        }
        if point.x > trailingEdge {
            return allowsPageNavigation ? .nextPage : .ignored
        }
        return .toggleChrome
    }
}
