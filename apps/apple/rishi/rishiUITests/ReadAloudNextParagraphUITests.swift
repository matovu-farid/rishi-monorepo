//
//  ReadAloudNextParagraphUITests.swift
//  rishiUITests
//
//  Reproduces the read-aloud "stuck on Loading…" bug on a passage switch.
//
//  Steps:
//    1. Launch with RISHI_UITEST=1 (DEBUG-only auth bypass + fixture TTS
//       source — see UITestSupport.swift). The app boots straight into the
//       library, fully offline and signed-out.
//    2. Open the auto-seeded sample book (alice.epub).
//    3. Tap Read Aloud, wait for the status label to read "Playing"
//       (passage 0 renders real audio through the production AVAudioEngine).
//    4. Tap Next paragraph and assert the status returns to "Playing".
//
//  Today this FAILS: `AVAudioPlayerNode.stop()/reset()` blocks on the
//  mid-passage switch, so the status latches on "Loading…" and never goes
//  back to "Playing". Once the player-node switch no longer blocks, the
//  status returns to "Playing" and the test passes.
//

import XCTest

final class ReadAloudNextParagraphUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNextParagraphReturnsToPlaying() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launch()

        // 1. Library — wait for the auto-seeded sample book cell to appear.
        let bookCell = app.descendants(matching: .any)
            .matching(identifier: "library-book-cell")
            .firstMatch
        XCTAssertTrue(
            bookCell.waitForExistence(timeout: 30),
            "Library never showed a book cell — auth bypass or sample-book seed failed."
        )
        robustTap(bookCell)

        // 2. Reader toolbar — under RISHI_UITEST the reader chrome starts visible,
        //    so the Read Aloud toolbar button is present once the reader opens.
        let readAloud = app.descendants(matching: .any)
            .matching(identifier: "reader.toolbar.readAloud")
            .firstMatch
        if !readAloud.waitForExistence(timeout: 15) {
            let snap = XCTAttachment(string: app.debugDescription)
            snap.name = "hierarchy-no-readaloud"
            snap.lifetime = .keepAlways
            add(snap)
        }
        XCTAssertTrue(
            readAloud.exists,
            "Read Aloud toolbar button never appeared — reader did not open."
        )
        robustTap(readAloud)

        // 3. Passage 0 — wait until the status label reads "Playing".
        let status = app.descendants(matching: .any)
            .matching(identifier: "tts-status")
            .firstMatch
        XCTAssertTrue(
            status.waitForExistence(timeout: 20),
            "TTS status label never appeared — read-aloud controls did not show."
        )
        XCTAssertTrue(
            waitForLabel(status, equals: "Playing", timeout: 15),
            "Passage 0 never reached Playing (label=\(status.label)). Offline TTS source failed."
        )

        // 4. Next paragraph — the mid-passage switch. ASSERT it returns to
        //    Playing within ~10s. Stuck on "Loading…" = the bug reproduced.
        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph")
            .firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next-paragraph button missing.")
        robustTap(next)

        XCTAssertTrue(
            waitForLabel(status, equals: "Playing", timeout: 10),
            "After Next paragraph the status stayed on \"\(status.label)\" (expected \"Playing\"). "
            + "Read-aloud is stuck — AVAudioPlayerNode.stop()/reset() blocked on the passage switch."
        )
    }

    /// Always taps by center coordinate. SwiftUI buttons in scroll views /
    /// overlays frequently report `isHittable=false` (or flap between true and
    /// false), and `element.tap()` then aborts the whole test ("Failed to not
    /// hittable"). A coordinate tap does no hittability check and is reliable for
    /// a visible element. Settles briefly first so the element's frame is stable.
    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Polls `element.label` until it equals `expected` or the timeout elapses.
    /// XCUIElement `label` is not KVO-observable, so we poll on a short cadence
    /// rather than rely on a single `NSPredicate` expectation snapshot.
    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        equals expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.label == expected {
                return true
            }
            usleep(200_000) // 200ms
        }
        return element.exists && element.label == expected
    }
}
