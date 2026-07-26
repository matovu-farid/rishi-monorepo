@testable import rishi
import Foundation
import Testing


@Suite("Placeholder")
struct RishiCore_PlaceholderTests {
    @Test func apiVersionIsSet() {
        #expect(RishiCore.apiVersion == "1.0.0")
    }
}
