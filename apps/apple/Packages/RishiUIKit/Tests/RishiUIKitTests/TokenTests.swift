import Foundation
import Testing
import CoreGraphics
@testable import RishiUIKit

@Suite("Design tokens")
struct TokenTests {

    @Test func spacingValues() {
        #expect(RishiSpacing.xxs  == 2)
        #expect(RishiSpacing.xs   == 4)
        #expect(RishiSpacing.s    == 8)
        #expect(RishiSpacing.m    == 12)
        #expect(RishiSpacing.l    == 16)
        #expect(RishiSpacing.xl   == 24)
        #expect(RishiSpacing.xxl  == 32)
        #expect(RishiSpacing.xxxl == 48)
    }

    @Test func radiusValues() {
        #expect(RishiRadius.small  == 6)
        #expect(RishiRadius.medium == 10)
        #expect(RishiRadius.large  == 16)
        #expect(RishiRadius.pill   == .infinity)
    }

    @Test func motionDurations() {
        #expect(RishiMotion.fast     == .milliseconds(180))
        #expect(RishiMotion.standard == .milliseconds(320))
        #expect(RishiMotion.slow     == .milliseconds(500))
    }

    @Test func designSystemPreviewInstantiates() {
        // The preview view must construct without crashing — exercises the
        // public initializer and confirms the type is publicly reachable.
        _ = DesignSystemPreview()
    }
}
