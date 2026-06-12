import Testing
import Foundation
@testable import RishiReader

/// Tests the small haptic helper. Production fires real `UIImpactFeedback`
/// / `UINotificationFeedback`; tests inject a fake so they record events
/// without depending on the device feedback generator.
@MainActor
@Suite("ReaderHaptics")
struct ReaderHapticsTests {

    final class FakeEngine: ReaderHapticsEngine {
        var events: [ReaderHapticEvent] = []
        func fire(_ event: ReaderHapticEvent) {
            events.append(event)
        }
    }

    @Test("Page-turn fires a light impact")
    func PageTurn_FiresLightImpact() {
        let engine = FakeEngine()
        let haptics = ReaderHaptics(engine: engine)

        haptics.pageTurn()

        #expect(engine.events == [.lightImpact])
    }

    @Test("Boundary fires a warning notification")
    func Boundary_FiresWarning() {
        let engine = FakeEngine()
        let haptics = ReaderHaptics(engine: engine)

        haptics.boundary()

        #expect(engine.events == [.warning])
    }
}
