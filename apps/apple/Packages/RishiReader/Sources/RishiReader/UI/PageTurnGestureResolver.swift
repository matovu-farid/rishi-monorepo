import Foundation
import CoreGraphics

/// Pure decision logic for a horizontal page-turn drag gesture.
///
/// Inputs:
///   * `translation`  — signed horizontal offset since the drag began
///                      (negative = dragged left = advance forward).
///   * `velocity`     — release velocity in points per second along the
///                      same axis.
///   * boundary flags — whether the document is currently on the first
///                      or last page so the resolver can refuse to
///                      commit past the edge.
///
/// Outputs:
///   * ``Decision/commitNext``     — finalize the page turn forward.
///   * ``Decision/commitPrevious`` — finalize backward.
///   * ``Decision/snapBack``       — return to the current page.
///   * ``Decision/boundaryBounce`` — user tried to swipe past an edge.
///
/// Keeping this in a pure struct (no SwiftUI) means the unit tests don't
/// need to spin views or simulate touches. The view layer wires the
/// resolver into a `DragGesture` and animates the resulting decision
/// with `withAnimation(.interactiveSpring(...))`.
public struct PageTurnGestureResolver: Sendable, Equatable {

    /// Outcome of evaluating a release on the page-turn gesture.
    public enum Decision: Sendable, Equatable {
        case commitNext
        case commitPrevious
        case snapBack
        case boundaryBounce
    }

    /// Width of one page in points. Used to translate the absolute drag
    /// offset into a fractional commit threshold (e.g. 40% of width).
    public let pageWidth: CGFloat

    /// Fraction of `pageWidth` at which a slow drag commits. Default
    /// matches Apple Books' "drag past the spine" feel.
    public let commitFraction: CGFloat

    /// Velocity at which a short drag still commits, in points per
    /// second. Default tuned for a flick gesture.
    public let commitVelocity: CGFloat

    public init(
        pageWidth: CGFloat,
        commitFraction: CGFloat = 0.4,
        commitVelocity: CGFloat = 800
    ) {
        self.pageWidth = pageWidth
        self.commitFraction = commitFraction
        self.commitVelocity = commitVelocity
    }

    /// Returns the decision for a release with the supplied translation
    /// and velocity. Boundary flags refuse to commit in their respective
    /// directions (returning `.boundaryBounce`) but allow the opposite
    /// direction to commit normally.
    public func decide(
        translation: CGFloat,
        velocity: CGFloat,
        isAtLeadingBoundary: Bool,
        isAtTrailingBoundary: Bool
    ) -> Decision {
        let goingForward  = translation < 0 || velocity < 0
        let goingBackward = translation > 0 || velocity > 0

        // Boundary check first — never commit past an edge.
        if goingForward, isAtTrailingBoundary {
            return .boundaryBounce
        }
        if goingBackward, isAtLeadingBoundary {
            return .boundaryBounce
        }

        let exceededFraction = abs(translation) >= pageWidth * commitFraction
        let exceededVelocity = abs(velocity)    >= commitVelocity
        let shouldCommit = exceededFraction || exceededVelocity

        guard shouldCommit else { return .snapBack }

        // Direction is decided by translation when present; otherwise
        // velocity (allows pure flick with no measurable translation).
        if translation < 0 || (translation == 0 && velocity < 0) {
            return .commitNext
        } else {
            return .commitPrevious
        }
    }

    /// Returns the translation to apply to the page view, damped by a
    /// rubber-band curve when the user drags past a boundary in the
    /// forbidden direction. Valid drags (within bounds) pass through
    /// unchanged.
    ///
    /// The curve `damped = raw * (1 - 1/(1 + |raw|/pageWidth))` matches
    /// the gentle exponential resistance UIScrollView uses at bounce
    /// edges. We re-derive it here so the resolver remains free of any
    /// UIKit dependency.
    public func rubberBandedTranslation(
        raw: CGFloat,
        isAtLeadingBoundary: Bool,
        isAtTrailingBoundary: Bool
    ) -> CGFloat {
        // Drag forward at the trailing edge => damp.
        if raw < 0, isAtTrailingBoundary {
            return -damp(magnitude: -raw)
        }
        // Drag backward at the leading edge => damp.
        if raw > 0, isAtLeadingBoundary {
            return damp(magnitude: raw)
        }
        return raw
    }

    private func damp(magnitude: CGFloat) -> CGFloat {
        // Guard against zero pageWidth in degenerate states.
        guard pageWidth > 0 else { return magnitude * 0.5 }
        let ratio = magnitude / pageWidth
        return magnitude * (1 - 1 / (1 + ratio))
    }
}
