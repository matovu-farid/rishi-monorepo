@testable import rishi
import Testing
import CoreGraphics


@Suite("RishiScreenLayout resolution")
struct RishiScreenLayoutTests {

    @Test("Mac Catalyst resolves to a centered 440pt column")
    func macResolvesToCenteredColumn() {
        #expect(
            RishiScreenLayout.resolve(isMacCatalyst: true)
                == .centeredColumn(maxWidth: 440)
        )
    }

    @Test("Non-Catalyst resolves to full-bleed")
    func nonMacResolvesToFullBleed() {
        #expect(RishiScreenLayout.resolve(isMacCatalyst: false) == .fullBleed)
    }
}
