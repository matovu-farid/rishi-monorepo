//
//  SettingsWindowSizingTests.swift
//  rishiTests
//
//  Phase 32 Plan 32-01 — pins the pure fixed-size + clamp math for the
//  dedicated Mac Settings window. Swift Testing only (no XCTest).
//

import Testing
import CoreGraphics
@testable import rishi

@Suite("SettingsWindowSizing")
struct SettingsWindowSizingTests {

    @Test("fixedSettingsSize is 720x640")
    func fixedSize() {
        #expect(SettingsWindowSizing.fixedSettingsSize == CGSize(width: 720, height: 640))
    }

    @Test("clamped raises a smaller existing size to the fixed size")
    func clampedRaisesSmaller() {
        let result = SettingsWindowSizing.clamped(existing: CGSize(width: 400, height: 300))
        #expect(result == CGSize(width: 720, height: 640))
    }

    @Test("clamped preserves a larger existing size (never shrinks)")
    func clampedPreservesLarger() {
        let existing = CGSize(width: 1000, height: 800)
        let result = SettingsWindowSizing.clamped(existing: existing)
        #expect(result == existing)
    }

    @Test("clamped is per-dimension: raises one axis, preserves the other")
    func clampedPerDimension() {
        let result = SettingsWindowSizing.clamped(existing: CGSize(width: 1000, height: 300))
        #expect(result == CGSize(width: 1000, height: 640))
    }
}
