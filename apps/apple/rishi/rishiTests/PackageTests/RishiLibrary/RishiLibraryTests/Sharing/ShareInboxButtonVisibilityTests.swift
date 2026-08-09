import Testing

@testable import rishi

@Suite("Share inbox toolbar visibility")
struct ShareInboxButtonVisibilityTests {
    @Test("shows the manual inbox action whenever sharing is available")
    func showsWhenAvailable() {
        #expect(ShareInboxButtonVisibility.shouldShow(shareServiceAvailable: true))
    }

    @Test("hides the manual inbox action when sharing is unavailable")
    func hidesWhenUnavailable() {
        #expect(!ShareInboxButtonVisibility.shouldShow(shareServiceAvailable: false))
    }
}
