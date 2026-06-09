import SwiftUI

private struct RishiAnimationModifier: ViewModifier {
    let duration: Duration
    let reduce: Bool

    func body(content: Content) -> some View {
        if reduce {
            content.transaction { $0.animation = nil }
        } else {
            content.animation(.easeInOut(duration: duration.seconds), value: UUID())
        }
    }
}

public extension View {
    /// Apply a Rishi motion token, honoring `accessibilityReduceMotion`.
    /// Pass the value from `@Environment(\.accessibilityReduceMotion) var reduceMotion`
    /// as `reduce`.
    func rishiAnimation(_ duration: Duration, reduce: Bool) -> some View {
        modifier(RishiAnimationModifier(duration: duration, reduce: reduce))
    }
}

private extension Duration {
    /// Convert a `Duration` to seconds as a `Double` for SwiftUI animation APIs.
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
