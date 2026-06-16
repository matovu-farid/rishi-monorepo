//
//  VoiceRestartUITests.swift
//  rishiUITests
//
//  Reproduction harness for the voice-chat auto-teardown bug.
//
//  DEVICE SYMPTOM (user-confirmed): a voice chat connects and goes live, then
//  IMMEDIATELY tears itself down. Device logs show, on EVERY call:
//    voice.adapter.connected
//    -> voice.session.live
//    -> voice.presenter.end isPresenting=true status=live trigger=user-button
//    -> voice.adapter.disconnected
//    -> audio.session.mode idle
//    -> voice.session.ended
//  The `trigger=user-button` proves VoiceSessionView's End button action
//  (`onEnd`) is being invoked right after the session reaches `.live`, even
//  though the user taps nothing. The user reports: "voice UI appears and stays,
//  I speak, nothing comes back, I tap nothing."
//
//  This test reproduces the user's steps: open a voice chat, end it, open a
//  second voice chat — and asserts the (second) session REACHES and STAYS live
//  without auto-ending. Because the device logs show even the FIRST call
//  auto-ends, it also asserts the FIRST opened session stays live.
//
//  OFFLINE DETERMINISM: under RISHI_UITEST=1 (see UITestSupport.swift +
//  AppDependencies + UITestVoiceFakes.swift) the voice stack is wired with
//  offline fakes — a `RealtimeClientAPI` that connects after a short delay and
//  STAYS connected (never self-disconnects), a canned ephemeral-key fetcher,
//  and an always-granted mic gate. So the session reaches `.live` with NO
//  network and NO system mic prompt. Any teardown this test observes is the
//  bug, not the fake dropping the session.
//
//  We assert on the "voice.end" button: it exists only while VoiceSessionHost
//  is presenting the live VoiceSessionView. If the End action auto-fires (the
//  bug), `presenter.end()` flips `isPresenting=false`, the fullScreenCover
//  dismisses, and "voice.end" disappears — so these waits fail.
//

import XCTest

final class VoiceRestartUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// start -> (stays live) -> end -> start -> (stays live) reproduction.
    @MainActor
    func testVoiceSessionStaysLiveAcrossRestart() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launch()

        // 1. Library — wait for the auto-seeded sample book cell, then open it.
        //    The reader chrome starts visible under RISHI_UITEST, so the
        //    toolbar (incl. the voice button) is present once the reader opens.
        openSeededBook(app)

        let voiceButton = app.descendants(matching: .any)
            .matching(identifier: "reader.toolbar.voice")
            .firstMatch
        XCTAssertTrue(
            voiceButton.waitForExistence(timeout: 15),
            "Voice toolbar button (reader.toolbar.voice) never appeared — reader did not open."
        )

        let endButton = app.descendants(matching: .any)
            .matching(identifier: "voice.end")
            .firstMatch

        // === FIRST SESSION ===
        // 2. Tap the voice button — VoiceSessionPresenter.start() runs the FSM
        //    to .live via the offline fakes and the fullScreenCover presents
        //    VoiceSessionView, exposing "voice.end".
        robustTap(voiceButton)
        XCTAssertTrue(
            endButton.waitForExistence(timeout: 20),
            "First voice session never presented — \"voice.end\" did not appear. "
            + "The offline fakes failed to reach .live, or the session auto-ended "
            + "before the surface mounted."
        )

        // REPRO ASSERTION 1 — first session STAYS live.
        // Without tapping ANYTHING, the End button must still exist after ~3s.
        // With the bug, onEnd auto-fires (trigger=user-button), presenter.end()
        // flips isPresenting=false, the cover dismisses, and "voice.end" is gone.
        assertStaysPresent(
            endButton,
            holdSeconds: 3,
            message: "FIRST voice session auto-ended: \"voice.end\" disappeared within "
            + "~3s with no user interaction. The End button action fired on its own "
            + "(trigger=user-button) and tore the session down."
        )

        // 3. End the first session deliberately and return to the reader.
        robustTap(endButton)
        XCTAssertTrue(
            voiceButton.waitForExistence(timeout: 15),
            "After ending the first session the reader toolbar voice button did not "
            + "reappear — the cover did not dismiss back to the reader."
        )

        // === SECOND SESSION (the user's reported restart) ===
        // 4. Tap the voice button again — second session should present.
        robustTap(voiceButton)
        XCTAssertTrue(
            endButton.waitForExistence(timeout: 20),
            "Second voice session never presented — \"voice.end\" did not appear after "
            + "restarting voice. The session failed to reach .live or auto-ended before "
            + "the surface mounted."
        )

        // REPRO ASSERTION 2 — second session STAYS live.
        // Same hold check after the start->end->start cycle.
        assertStaysPresent(
            endButton,
            holdSeconds: 3,
            message: "SECOND voice session auto-ended: \"voice.end\" disappeared within "
            + "~3s with no user interaction after the start->end->start cycle. The End "
            + "button action fired on its own (trigger=user-button) and tore the session down."
        )
    }

    // MARK: - Helpers

    /// Library -> open the auto-seeded sample book (alice.epub). Mirrors the
    /// proven bootstrap used by the read-aloud UITests.
    @MainActor
    private func openSeededBook(_ app: XCUIApplication) {
        let bookCell = app.descendants(matching: .any)
            .matching(identifier: "library-book-cell")
            .firstMatch
        XCTAssertTrue(
            bookCell.waitForExistence(timeout: 30),
            "Library never showed a book cell — auth bypass or sample-book seed failed."
        )
        robustTap(bookCell)
    }

    /// Asserts `element` remains present for the entire `holdSeconds` window
    /// without re-tapping anything. Polls roughly twice a second; the moment the
    /// element disappears the test fails with `message` — this is the signature
    /// of the session auto-ending (the bug). If it survives the whole window the
    /// session stayed live.
    @MainActor
    private func assertStaysPresent(
        _ element: XCUIElement,
        holdSeconds: Int,
        message: String
    ) {
        let polls = max(1, holdSeconds * 2)
        for _ in 0..<polls {
            usleep(500_000)
            XCTAssertTrue(element.exists, message)
        }
    }

    /// Always taps by center coordinate. SwiftUI buttons in scroll views /
    /// overlays frequently report isHittable=false (or flap), and
    /// `element.tap()` then aborts the whole test. A coordinate tap does no
    /// hittability check. Settles briefly first so the frame is stable.
    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
