@testable import rishi
//
//  ReadAloudScrollTargetTests.swift
//  RishiReaderTests
//
//  Locks the pure Mode-A read-aloud auto-scroll offset math (Phase 30, plan
//  30-02). Given the spoken passage's top edge in content coordinates, the
//  viewport height, and the content height, compute the vertical content offset
//  that anchors the passage `topMargin` points below the viewport top, clamped to
//  the valid scroll range [0, contentHeight - viewportHeight].
//
//  Mirrors RESEARCH's "Auto-scroll at the existing seam (Mode A)": the
//  `- 80` upper-margin anchoring + `max(0, ...)` clamp extracted into pure,
//  testable math (the UIKit glue that converts PDF page rects into content
//  coordinates lives in plan 30-05).
//

import Testing
import CoreGraphics


@Suite("ReadAloudScrollTarget")
struct ReadAloudScrollTargetTests {

    @Test("passage well below the fold anchors at passageMinY - topMargin")
    func belowFoldAnchorsWithMargin() {
        let target = ReadAloudScrollTarget.targetOffsetY(
            passageMinY: 1000,
            viewportHeight: 600,
            contentHeight: 4000,
            topMargin: 80
        )
        #expect(target == 920)            // 1000 - 80, well within [0, 3400]
    }

    @Test("result is clamped to >= 0 (never a negative offset)")
    func clampsToZeroLowerBound() {
        // passageMinY - topMargin would be negative (40 - 80 = -40); clamp to 0.
        let target = ReadAloudScrollTarget.targetOffsetY(
            passageMinY: 40,
            viewportHeight: 600,
            contentHeight: 4000,
            topMargin: 80
        )
        #expect(target == 0)
    }

    @Test("result is clamped to <= max(0, contentHeight - viewportHeight)")
    func clampsToMaxOffset() {
        // Desired 3900 - 80 = 3820, but maxOffset = 4000 - 600 = 3400.
        let target = ReadAloudScrollTarget.targetOffsetY(
            passageMinY: 3900,
            viewportHeight: 600,
            contentHeight: 4000,
            topMargin: 80
        )
        #expect(target == 3400)
    }

    @Test("passage already within topMargin of the top returns 0 (clamped, not negative)")
    func passageNearTopReturnsZero() {
        let target = ReadAloudScrollTarget.targetOffsetY(
            passageMinY: 50,              // 50 - 80 = -30 -> clamp 0
            viewportHeight: 600,
            contentHeight: 4000,
            topMargin: 80
        )
        #expect(target == 0)
    }

    @Test("content shorter than viewport clamps maxOffset to 0")
    func shortContentClampsToZero() {
        // maxOffset = max(0, 300 - 600) = 0, so any positive desired clamps to 0.
        let target = ReadAloudScrollTarget.targetOffsetY(
            passageMinY: 200,
            viewportHeight: 600,
            contentHeight: 300,
            topMargin: 80
        )
        #expect(target == 0)
    }

    @Test("default topMargin is 80 (matches RESEARCH anchoring)")
    func defaultTopMarginIs80() {
        #expect(ReadAloudScrollTarget.defaultTopMargin == 80)
        // Calling without an explicit topMargin uses the 80 default.
        let target = ReadAloudScrollTarget.targetOffsetY(
            passageMinY: 1000,
            viewportHeight: 600,
            contentHeight: 4000
        )
        #expect(target == 920)            // 1000 - 80
    }
}
