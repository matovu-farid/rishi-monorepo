//
//  ReadAloudNextParagraphUITests.swift
//  rishiUITests
//
//  Regression guard for the read-aloud "stuck on Loading…" deadlock on a
//  passage switch (fixed: AVAudioEngineAdapter no longer calls
//  playerNode.stop()/reset() while holding its lock).
//
//  Steps:
//    1. Launch with RISHI_UITEST=1 (DEBUG-only auth bypass + fixture TTS
//       source — see UITestSupport.swift). The app boots straight into the
//       library, fully offline and signed-out.
//    2. Open the auto-seeded sample book (alice.epub). It opens on the COVER
//       (image only — no paragraphs), so Read Aloud no-ops there
//       (startReadAloud guards `!paragraphs.isEmpty`). Advance pages until a
//       Read Aloud session actually starts (controls overlay appears).
//    3. Passage 0 renders real audio through the production AVAudioEngine.
//       Assert it reaches Playing.
//    4. Tap Next paragraph and assert playback returns to Playing.
//
//  We assert on the play/pause TOGGLE BUTTON, not the status Text: when
//  status == .playing the toggle exposes accessibilityIdentifier
//  "tts-pause"; otherwise (idle/loading/paused) it is "tts-play". XCUITest
//  queries the Button reliably, whereas the bare status Text's value is not
//  exposed. If the deadlock regresses, the switch latches on Loading, the
//  toggle stays "tts-play" (disabled), and "tts-pause" never reappears — so
//  this test fails.
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
        //    The Readium webview's a11y subtree is hidden under RISHI_UITEST
        //    (see EPUBReaderView) and the chrome is pinned visible (no
        //    auto-hide), so these queries resolve cleanly on text-heavy pages.
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

        // The play/pause toggle: "tts-play" while idle/loading/paused,
        // "tts-pause" while playing. Either id means a session has STARTED.
        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'tts-play' OR identifier == 'tts-pause'")
        ).firstMatch

        // 2b. The book opens on the cover (no paragraphs). Tap Read Aloud, and
        //     if no session starts, turn the page and retry until a text page
        //     yields paragraphs and the controls overlay appears.
        //
        //     A page turn is a user navigation whose Readium locationDidChange
        //     callback is DELAYED (it lands after the animated `goForward`
        //     settles). That callback fires `onUserNavigation -> stopReadAloud`.
        //     If we start read-aloud too soon after a turn, the still-pending
        //     callback lands afterward and kills the fresh session. So we let
        //     each turn's callback drain before the next attempt, and below we
        //     restart once if a straggler still slips through.
        var sessionStarted = false
        for _ in 0..<8 {
            robustTap(readAloud)
            if toggle.waitForExistence(timeout: 4) {
                sessionStarted = true
                break
            }
            turnPageForward(app)
            usleep(1_500_000) // let the page-turn's user-nav callback drain
        }
        if !sessionStarted {
            let snap = XCTAttachment(string: app.debugDescription)
            snap.name = "hierarchy-no-session"
            snap.lifetime = .keepAlways
            add(snap)
        }
        XCTAssertTrue(
            sessionStarted,
            "Read Aloud never started a session on any page — no \"tts-play\"/\"tts-pause\" "
            + "control appeared. Paragraph extraction or the offline TTS source failed."
        )

        // A page turn just before the session started can deliver a straggler
        // user-nav callback that stops read-aloud. Let it drain; if the session
        // was killed, restart it (now on the content page, no pending turn).
        usleep(2_500_000)
        if !toggle.exists {
            robustTap(readAloud)
            XCTAssertTrue(
                toggle.waitForExistence(timeout: 6),
                "Read-aloud could not be restarted on the content page after a "
                + "straggler page-turn navigation stopped the first session."
            )
        }

        // 3. Passage 0 — playback reaches Playing. When playing the toggle
        //    exposes "tts-pause".
        let pause = app.descendants(matching: .any)
            .matching(identifier: "tts-pause").firstMatch
        if !pause.waitForExistence(timeout: 25) {
            let snap = XCTAttachment(string: app.debugDescription)
            snap.name = "hierarchy-no-playing"
            snap.lifetime = .keepAlways
            add(snap)
        }
        XCTAssertTrue(
            pause.exists,
            "Passage 0 never reached Playing (no \"tts-pause\" button). "
            + "The offline TTS source failed to render audio."
        )

        // 4. Next paragraph — the mid-passage switch that used to deadlock.
        //    The toggle briefly flips to "tts-play" (loading) and must return
        //    to "tts-pause" (playing). Stuck on Loading = the deadlock: the
        //    toggle stays "tts-play" and "tts-pause" never reappears.
        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next-paragraph button missing.")
        robustTap(next)

        // Let the loading transition begin so we don't observe the stale
        // pre-switch "tts-pause" from passage 0.
        usleep(1_000_000)

        let resumed = app.descendants(matching: .any)
            .matching(identifier: "tts-pause").firstMatch
        XCTAssertTrue(
            resumed.waitForExistence(timeout: 15),
            "After Next paragraph, playback never returned to Playing "
            + "(\"tts-pause\" never reappeared). Read-aloud is stuck on Loading — "
            + "AVAudioPlayerNode.stop()/reset() blocked on the passage switch."
        )
    }

    /// Regression guard for the PAGE-BOUNDARY halt (Bug 4): read-aloud
    /// auto/next-advances fine WITHIN a Readium page, but when an advance moves
    /// the highlight onto a paragraph that is OFF the current page, the reader
    /// programmatically animates to the next page
    /// (`EPUBNavigatorCoordinator.navigateToReadAloudParagraph` ->
    /// `nav.go(to:, animated:true)`). That animated nav delivers a DELAYED
    /// `locationDidChange`. The coordinator resets `isProgrammaticNavigation`
    /// synchronously the instant `go(to:)` returns, so the late callback is
    /// misread as a USER navigation and fires `onUserNavigation -> stopReadAloud`.
    /// Device symptom (user-confirmed): the new page's first paragraph
    /// highlights and starts playing, then HALTS a moment later.
    ///
    /// Read-aloud paragraphs span the whole chapter (~34 for alice ch.1), so
    /// pressing Next repeatedly keeps advancing within one resource and is
    /// guaranteed to eventually step onto an off-page paragraph — triggering
    /// the programmatic page turn. After EACH Next we require playback to
    /// return to Playing AND to STAY Playing through a short hold: a
    /// page-crossing Next that halts will lose "tts-pause" when the delayed
    /// callback lands and never get it back (the session is stopped, not
    /// merely loading the next passage). A transient auto-advance blip is
    /// tolerated because the second wait re-checks for up to 6s.
    @MainActor
    func testCrossingPageBoundaryKeepsPlaying() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launch()

        let (readAloud, toggle) = startPlayingSession(app)
        _ = toggle

        // Confirm we are Playing on the first passage before we begin crossing.
        let pause = app.descendants(matching: .any)
            .matching(identifier: "tts-pause").firstMatch
        XCTAssertTrue(
            pause.waitForExistence(timeout: 25),
            "Session did not reach Playing before the page-boundary sweep."
        )

        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next-paragraph button missing.")

        // Step through enough paragraphs to cross at least one page boundary.
        // 12 presses from near the chapter start clears a phone page (which
        // holds only a handful of paragraphs) while staying within the ~34
        // paragraphs of the resource.
        for press in 1...12 {
            robustTap(next)

            // The switch flips to Loading ("tts-play"); let it begin so we
            // don't observe the stale pre-switch "tts-pause".
            usleep(800_000)

            XCTAssertTrue(
                pause.waitForExistence(timeout: 15),
                "After Next #\(press), playback never returned to Playing "
                + "(\"tts-pause\" missing). If this is the page-crossing press, "
                + "the new page's paragraph never started — the delayed "
                + "page-turn navigation stopped read-aloud."
            )

            // Let any DELAYED locationDidChange from a programmatic page turn
            // land. If this Next crossed a page boundary on the buggy build,
            // the late callback fires onUserNavigation -> stopReadAloud here
            // and tears the session down.
            usleep(2_000_000)

            // Re-check with a short wait so a transient auto-advance Loading
            // blip is tolerated, but a stopped session is not.
            XCTAssertTrue(
                pause.waitForExistence(timeout: 6),
                "After Next #\(press), playback STARTED then HALTED — "
                + "\"tts-pause\" disappeared and did not return. This is the "
                + "page-boundary stop: the programmatic page turn's delayed "
                + "locationDidChange was misread as a user navigation and "
                + "fired stopReadAloud. The Read Aloud button still present: "
                + "\(readAloud.exists)."
            )
        }
    }

    /// Drives Library -> open the sample book -> start a Read Aloud session and
    /// returns once playback has begun (a "tts-play"/"tts-pause" toggle exists).
    /// Mirrors the proven bootstrap in `testNextParagraphReturnsToPlaying`
    /// (advance past the cover, drain the page-turn callback, self-heal one
    /// straggler stop) so both tests share the same reliable starting point.
    /// Returns the Read Aloud toolbar button and the play/pause toggle.
    @MainActor
    private func startPlayingSession(_ app: XCUIApplication) -> (XCUIElement, XCUIElement) {
        let bookCell = app.descendants(matching: .any)
            .matching(identifier: "library-book-cell")
            .firstMatch
        XCTAssertTrue(
            bookCell.waitForExistence(timeout: 30),
            "Library never showed a book cell — auth bypass or sample-book seed failed."
        )
        robustTap(bookCell)

        let readAloud = app.descendants(matching: .any)
            .matching(identifier: "reader.toolbar.readAloud")
            .firstMatch
        XCTAssertTrue(
            readAloud.waitForExistence(timeout: 15),
            "Read Aloud toolbar button never appeared — reader did not open."
        )

        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'tts-play' OR identifier == 'tts-pause'")
        ).firstMatch

        var sessionStarted = false
        for _ in 0..<8 {
            robustTap(readAloud)
            if toggle.waitForExistence(timeout: 4) {
                sessionStarted = true
                break
            }
            turnPageForward(app)
            usleep(1_500_000)
        }
        XCTAssertTrue(
            sessionStarted,
            "Read Aloud never started a session on any page."
        )

        usleep(2_500_000)
        if !toggle.exists {
            robustTap(readAloud)
            XCTAssertTrue(
                toggle.waitForExistence(timeout: 6),
                "Read-aloud could not be restarted on the content page after a "
                + "straggler page-turn navigation stopped the first session."
            )
        }
        return (readAloud, toggle)
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

    /// Turns the reader forward one page by tapping the right region, which the
    /// reader's tap-region resolver maps to `navigator.goForward` (see
    /// EPUBReaderScreen.onTap). A right-edge tap (dx 0.9) is firmly in the
    /// next-page third, away from the center chrome-toggle region. We tap app
    /// coordinates rather than the webview element because the webview's a11y
    /// subtree is hidden under RISHI_UITEST. Settles so pagination completes.
    @MainActor
    private func turnPageForward(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        usleep(600_000)
    }
}
