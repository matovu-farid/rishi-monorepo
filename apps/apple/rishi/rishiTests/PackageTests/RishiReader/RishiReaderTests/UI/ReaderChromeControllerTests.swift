@testable import rishi
import Testing
import Foundation


/// Tests for the tap-to-toggle / auto-hiding reader chrome controller.
///
/// Mirrors the iBooks behavior: chrome starts hidden, tap toggles it on,
/// it auto-hides after an idle period, and VoiceOver users keep chrome
/// visible (auto-hide is skipped).
///
/// The controller injects an `AccessibilityProviding` flag and a sleep
/// closure so tests can simulate the idle timer without real wall-clock
/// waits. Production wires `UIAccessibility.isVoiceOverRunning` and
/// `Task.sleep(for:)`.
@MainActor
@Suite("ReaderChromeController", .serialized)
struct ReaderChromeControllerTests {

    /// Records every `isVoiceOverRunning` read; lets tests toggle the value
    /// to simulate the user enabling VoiceOver mid-session.
    final class FakeAccessibility: AccessibilityProviding {
        var voiceOver: Bool
        init(voiceOver: Bool) { self.voiceOver = voiceOver }
        var isVoiceOverRunning: Bool { voiceOver }
    }

    /// A controllable sleep: the test calls `waitForSleep()` to wait until
    /// the controller has suspended on `sleep(for:)`, then `fire()` /
    /// `cancel()` to resume the suspension. Without that handshake the
    /// test races the controller's spawned Task and the continuation may
    /// not yet be installed when the test tries to resolve it.
    final class FakeSleeper: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Error>?
        private var pendingWaiters: [CheckedContinuation<Void, Never>] = []
        var sleepCallCount = 0

        func sleep(for: Duration) async throws {
            sleepCallCount += 1
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                // Wake anyone waiting for "the controller is now suspended".
                let waiters = self.pendingWaiters
                self.pendingWaiters = []
                for w in waiters { w.resume() }
            }
        }

        /// Suspend until the controller is parked inside `sleep(for:)`.
        func waitForSleep() async {
            if continuation != nil { return }
            await withCheckedContinuation { cont in
                self.pendingWaiters.append(cont)
            }
        }

        /// Resolve the pending sleep so the auto-hide branch runs.
        func fire() {
            let c = continuation
            continuation = nil
            c?.resume(returning: ())
        }

        /// Resolve the pending sleep with a cancellation error.
        func cancel() {
            let c = continuation
            continuation = nil
            c?.resume(throwing: CancellationError())
        }
    }

    @Test("Chrome starts hidden on entry")
    func chromeStartsHiddenOnEntry() {
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { _ in }
        )
        #expect(controller.isVisible == false)
    }

    @Test("Tap toggles chrome visibility")
    func tapTogglesChromeVisibility() {
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { _ in }
        )

        controller.toggle()
        #expect(controller.isVisible == true)

        controller.toggle()
        #expect(controller.isVisible == false)
    }

    @Test("Auto-hide fires after idle delay")
    func autoHideFiresAfterIdle() async {
        let sleeper = FakeSleeper()
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        controller.show()
        #expect(controller.isVisible == true)
        // Wait for the controller's Task to suspend inside sleep().
        await sleeper.waitForSleep()

        // Resolve the sleep so the auto-hide branch runs.
        sleeper.fire()
        // Yield so the awaiting Task can resume and set isVisible = false.
        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(controller.isVisible == false)
    }

    @Test("Hide cancels in-flight auto-hide timer")
    func autoHideCancelledOnHide() async {
        let sleeper = FakeSleeper()
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        controller.show()
        await sleeper.waitForSleep()
        controller.hide()
        // Pending sleep gets cancelled internally; resolving it here mimics
        // the cancellation path firing. The controller MUST NOT re-set
        // isVisible based on this delayed cancellation.
        sleeper.cancel()
        await Task.yield()
        await Task.yield()

        #expect(controller.isVisible == false)
    }

    @Test("Toggling hidden chrome shows it; toggling visible chrome hides immediately")
    func toggleHidesWhenVisible() async {
        let sleeper = FakeSleeper()
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        controller.toggle() // show
        #expect(controller.isVisible == true)

        controller.toggle() // hide immediately
        #expect(controller.isVisible == false)
    }

    @Test("VoiceOver keeps chrome visible and skips auto-hide")
    func accessibilityKeepsChromeVisible() async {
        let a11y = FakeAccessibility(voiceOver: true)
        let sleeper = FakeSleeper()
        let controller = ReaderChromeController(
            accessibility: a11y,
            autoHideDelay: .seconds(4),
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        controller.show()
        #expect(controller.isVisible == true)
        // No sleep should have been scheduled because VoiceOver is on.
        #expect(sleeper.sleepCallCount == 0)
    }

    @Test("Always-visible mode starts visible")
    func alwaysVisibleStartsVisible() {
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { _ in },
            alwaysVisible: true
        )
        #expect(controller.isVisible == true)
    }

    @Test("Always-visible mode ignores toggle and stays visible")
    func alwaysVisibleIgnoresToggle() {
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { _ in },
            alwaysVisible: true
        )

        controller.toggle()
        #expect(controller.isVisible == true)
    }

    @Test("Always-visible mode ignores hide")
    func alwaysVisibleIgnoresHide() {
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { _ in },
            alwaysVisible: true
        )

        controller.hide()
        #expect(controller.isVisible == true)
    }

    @Test("Always-visible mode never schedules auto-hide")
    func alwaysVisibleSkipsAutoHide() async {
        let sleeper = FakeSleeper()
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { duration in try await sleeper.sleep(for: duration) },
            alwaysVisible: true
        )

        controller.show()
        #expect(controller.isVisible == true)
        #expect(sleeper.sleepCallCount == 0)
    }

    @Test("Activity resets the auto-hide timer")
    func activityResetsTimer() async {
        let sleeper = FakeSleeper()
        let controller = ReaderChromeController(
            accessibility: FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        controller.show()
        await sleeper.waitForSleep()
        #expect(sleeper.sleepCallCount == 1)

        // User interacts with the toolbar — reset the timer. Cancelling
        // the in-flight sleep needs to resolve the parked continuation so
        // the controller's `Task.sleep` rethrows and unwinds.
        controller.userActivity()
        sleeper.cancel() // drain the first sleep's parked continuation
        await sleeper.waitForSleep()

        #expect(sleeper.sleepCallCount == 2)
        #expect(controller.isVisible == true)
    }
}
