import Foundation
import Testing
@testable import RishiTesting

@Suite("RishiTesting placeholder")
struct PlaceholderTests {
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
