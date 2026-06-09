import Foundation
import Testing
@testable import RishiCore

@Suite("Placeholder")
struct PlaceholderTests {
    @Test func apiVersionIsSet() {
        #expect(RishiCore.apiVersion == "1.0.0")
    }
}
