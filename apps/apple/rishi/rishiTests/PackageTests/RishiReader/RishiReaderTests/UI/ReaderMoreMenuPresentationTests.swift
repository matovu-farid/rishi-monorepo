@testable import rishi
import SwiftUI
import Testing

@MainActor
@Suite("ReaderMoreMenuPresentation", .serialized)
struct ReaderMoreMenuPresentationTests {

    @Test("Presented More menu pauses chrome auto-hide until dismissed")
    func presentedMenuPausesAutoHideUntilDismissed() async {
        let sleeper = ReaderChromeControllerTests.FakeSleeper()
        let chrome = ReaderChromeController(
            accessibility: ReaderChromeControllerTests.FakeAccessibility(voiceOver: false),
            autoHideDelay: .seconds(4),
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )
        let presentation = ReaderMoreMenuPresentation(chrome: chrome)

        chrome.show()
        await sleeper.waitForSleep()
        presentation.binding.wrappedValue = true
        sleeper.fire()
        await Task.yield()

        #expect(presentation.isPresented)
        #expect(chrome.isVisible)
        #expect(sleeper.sleepCallCount == 1)

        presentation.binding.wrappedValue = false
        await sleeper.waitForSleep()
        #expect(!presentation.isPresented)
        #expect(chrome.isVisible)
        #expect(sleeper.sleepCallCount == 2)

        sleeper.fire()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while chrome.isVisible && clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        #expect(!chrome.isVisible)
    }
}
