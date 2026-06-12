import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Discrete haptic events fired by the reader. Kept as a flat enum so
/// the test fake can simply record them as an array.
public enum ReaderHapticEvent: Sendable, Equatable {
    case lightImpact
    case warning
}

/// Engine abstraction so tests can swap in a recording fake. Production
/// passes ``UIKitReaderHapticsEngine`` which fires real
/// `UIImpactFeedback` / `UINotificationFeedback`.
@MainActor
public protocol ReaderHapticsEngine: AnyObject {
    func fire(_ event: ReaderHapticEvent)
}

/// Reader-facing helper. Centralizes the haptic-firing contract so the
/// view layer just calls `haptics.pageTurn()` / `haptics.boundary()`.
@MainActor
public final class ReaderHaptics {
    private let engine: ReaderHapticsEngine

    public init(engine: ReaderHapticsEngine) {
        self.engine = engine
    }

    public func pageTurn() {
        engine.fire(.lightImpact)
    }

    public func boundary() {
        engine.fire(.warning)
    }
}

#if canImport(UIKit)
/// Default production engine. Prepares each generator lazily so the
/// first tap doesn't pay the activation cost.
@MainActor
public final class UIKitReaderHapticsEngine: ReaderHapticsEngine {
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    public init() {
        impact.prepare()
        notification.prepare()
    }

    public func fire(_ event: ReaderHapticEvent) {
        switch event {
        case .lightImpact:
            impact.impactOccurred()
            impact.prepare()
        case .warning:
            notification.notificationOccurred(.warning)
            notification.prepare()
        }
    }
}
#endif
