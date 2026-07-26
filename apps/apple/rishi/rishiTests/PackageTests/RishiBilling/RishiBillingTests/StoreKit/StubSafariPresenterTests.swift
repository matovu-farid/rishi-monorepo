@testable import rishi
import Foundation
import Testing

@Suite("StubSafariPresenter")
struct StubSafariPresenterTests {

    @Test("present(url:) appends the url to calls")
    func testCapturesURL() async {
        let presenter = StubSafariPresenter()
        let url = URL(string: "https://rishi.fidexa.org/terms")!
        await presenter.present(url: url)
        #expect(presenter.calls == [url])
    }
}
