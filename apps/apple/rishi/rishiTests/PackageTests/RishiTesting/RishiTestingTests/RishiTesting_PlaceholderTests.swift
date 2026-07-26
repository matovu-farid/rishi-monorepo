@testable import rishi
import Foundation
import Testing


@Suite("RishiTesting placeholder")
struct RishiTesting_PlaceholderTests {
    @Test func apiVersionExposed() {
        #expect(!RishiTesting.apiVersion.isEmpty)
    }

    @Test func rishiTestingErrorMessages() {
        let e1 = RishiTestingError.expected("foo")
        let e2 = RishiTestingError.unexpected("bar")
        #expect(e1.description.contains("foo"))
        #expect(e2.description.contains("bar"))
    }
}
