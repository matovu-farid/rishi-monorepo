import Foundation
import Testing
@testable import RishiTesting

@Suite("RishiTesting placeholder")
struct PlaceholderTests {
    @Test func placeholderExposed() {
        #expect(RishiTesting.placeholder == "RishiTesting")
    }
}
