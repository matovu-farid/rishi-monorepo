import Testing
import CoreGraphics
@testable import RishiOnboarding

@Suite("OnboardingLayoutMode resolution")
struct OnboardingLayoutModeTests {

    @Test("Mac Catalyst resolves to a centered 440pt column")
    func macResolvesToCenteredColumn() {
        #expect(
            OnboardingLayoutMode.resolve(isMacCatalyst: true)
                == .centeredColumn(maxWidth: 440)
        )
    }

    @Test("Non-Catalyst resolves to full-bleed")
    func nonMacResolvesToFullBleed() {
        #expect(OnboardingLayoutMode.resolve(isMacCatalyst: false) == .fullBleed)
    }
}
