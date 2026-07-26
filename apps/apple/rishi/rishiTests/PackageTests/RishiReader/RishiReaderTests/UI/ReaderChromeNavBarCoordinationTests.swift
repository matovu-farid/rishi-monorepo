@testable import rishi
import Testing
import SwiftUI


/// Phase 18 Plan 18-01 — F-P0-04 nav-bar visibility tracks chrome state.
///
/// The unconditional `.toolbar(.hidden, for: .navigationBar)` modifier in
/// ReaderScreen / PDFReaderScreen used to hide the system back chevron
/// even when the in-app chrome was visible. Now both screens compute
/// `Visibility` from `chrome.isVisible` via the tiny pure
/// `navBarVisibility(forChromeVisible:)` function — easy to lock down in a
/// Swift Testing suite without spinning up SwiftUI.
@MainActor
@Suite("ReaderChromeNavBarCoordination")
struct ReaderChromeNavBarCoordinationTests {

    @Test("Chrome visible → nav bar visible")
    func chromeVisibleResolvesToVisible() {
        #expect(navBarVisibility(forChromeVisible: true) == Visibility.visible)
    }

    @Test("Chrome hidden → nav bar hidden")
    func chromeHiddenResolvesToHidden() {
        #expect(navBarVisibility(forChromeVisible: false) == Visibility.hidden)
    }

    @Test("Default ReaderChromeController initializer hides chrome (initiallyVisible defaults to false)")
    func defaultControllerHidesChrome() {
        let controller = ReaderChromeController(accessibility: StubAccessibility())
        #expect(controller.isVisible == false)
        #expect(navBarVisibility(forChromeVisible: controller.isVisible) == Visibility.hidden)
    }

    @Test("Toggling chrome flips nav-bar visibility")
    func togglingChromeFlipsResolvedVisibility() {
        let controller = ReaderChromeController(accessibility: StubAccessibility())
        let before = navBarVisibility(forChromeVisible: controller.isVisible)
        controller.toggle()
        let after = navBarVisibility(forChromeVisible: controller.isVisible)
        #expect(before != after)
    }
}

@MainActor
private final class StubAccessibility: AccessibilityProviding {
    var isVoiceOverRunning: Bool { false }
}
