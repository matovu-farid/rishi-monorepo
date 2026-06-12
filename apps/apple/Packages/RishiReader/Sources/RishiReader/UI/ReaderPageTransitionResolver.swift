import Foundation

/// Selects a transition style for a page turn. Pulled out as a pure
/// struct so the reduce-motion fallback can be unit-tested without
/// spinning SwiftUI views.
///
/// The view layer maps each style onto an `AnyTransition` value — see
/// ``PageTurnAnimator`` for the concrete mapping.
public struct ReaderPageTransitionResolver: Sendable, Equatable {

    public enum Style: Sendable, Equatable {
        case slideForward
        case slideBackward
        case crossFade
    }

    public init() {}

    /// Returns the transition style for the supplied direction. When
    /// `reduceMotion` is true, both directions collapse to a cross-fade
    /// so vestibular-sensitive users never see a sliding panel.
    public func style(forward: Bool, reduceMotion: Bool) -> Style {
        if reduceMotion { return .crossFade }
        return forward ? .slideForward : .slideBackward
    }
}
