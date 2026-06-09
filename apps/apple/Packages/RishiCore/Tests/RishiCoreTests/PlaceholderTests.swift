import Foundation
import Testing
@testable import RishiCore

@Suite("Placeholder")
struct PlaceholderTests {
    @Test func packageBuilds() {
        #expect(RishiCore.placeholder == "RishiCore")
    }
}
