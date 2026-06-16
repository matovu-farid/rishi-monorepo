//
//  VoiceLiveRestartUITests.swift
//  rishiUITests
//
//  OPT-IN, LIVE-API reproduction of the voice-chat auto-teardown bug.
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
//  (`onEnd`) fires right after the session reaches `.live`, even though the
//  user taps nothing.
//
//  WHY A SEPARATE LIVE TEST: the offline VoiceRestartUITests drives the FSM
//  with fakes (a RealtimeClientAPI that connects and STAYS connected). That is
//  great for the FSM, but the real-world bug only manifests against the REAL
//  RealtimeAPIAdapter + real EphemeralKeyFetcher hitting the live worker /
//  OpenAI. This test launches the app in `RISHI_UITEST_LIVE_VOICE=1` mode:
//  it REUSES all the offline RISHI_UITEST stubs for sign-in, pro entitlement,
//  the seeded book and the visible reader chrome, but runs the PRODUCTION
//  voice stack (see AppDependencies + UITestSupport.swift). Worker auth uses
//  the dev-bypass header (X-Dev-Bypass = DEV_BYPASS_SECRET) so the realtime
//  client-secret call authenticates as `dev-user` with no real session.
//
//  OPT-IN / COST GUARD: this test makes PAID OpenAI calls, so it SKIPS unless
//  `DEV_BYPASS_SECRET` is exported into the test process environment. Normal
//  CI / local runs without the secret stay green-by-skip and incur no cost.
//
//  MIC PERMISSION (WebRTC gate): the realtime SDK hard-throws unless
//  `AVAudioApplication.shared.recordPermission == .granted`. In live-voice
//  mode AppDependencies wires the REAL SystemMicPermissionGate, so `start()`
//  actually requests OS permission. On a PHYSICAL DEVICE (primary target) a
//  fresh install is `.undetermined`, the system prompt appears, and the
//  UIInterruptionMonitor below auto-accepts it. On a SIMULATOR there is no
//  prompt to accept; pre-grant instead:
//      xcrun simctl privacy booted grant microphone org.fidexa.rishi
//  Reaching `.connected` only needs the data channel open (not live audio
//  frames), so a device run is the reliable target; the simulator is flaky.
//
//  We assert on the "voice.end" button: it exists only while VoiceSessionHost
//  is presenting the live VoiceSessionView. If the End action auto-fires (the
//  bug), `presenter.end()` flips `isPresenting=false`, the fullScreenCover
//  dismisses, and "voice.end" disappears — so the hold checks fail (red).
//  After the fix it stays present -> green.
//

import XCTest

final class VoiceLiveRestartUITests: XCTestCase {

    /// Dev-bypass secret read once in setUp; non-nil only when the test runs.
    private var devBypassSecret: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = false

        // OPT-IN: require the dev-bypass secret in the TEST process env. Without
        // it we cannot authenticate to the live worker, and we must not make
        // paid OpenAI calls in a default run — so SKIP (not fail).
        guard let secret = ProcessInfo.processInfo.environment["DEV_BYPASS_SECRET"],
              !secret.isEmpty else {
            throw XCTSkip(
                "Set DEV_BYPASS_SECRET to run the live-API voice repro test. "
                + "Without it this test skips (it makes paid OpenAI calls)."
            )
        }
        devBypassSecret = secret
    }

    /// LIVE start -> (stays live) -> end -> start -> (stays live) reproduction.
    @MainActor
    func testLiveVoiceSessionStaysLiveAcrossRestart() throws {
        let app = XCUIApplication()
        // Live-voice launch mode: reuse offline auth/book/chrome stubs, run the
        // REAL voice stack. RISHI_DEV_BYPASS=1 + the forwarded secret make the
        // WorkerClient attach X-Dev-Bypass so the realtime client-secret call
        // authenticates as `dev-user` against the live worker.
        // RISHI_UITEST=1 in ADDITION to the live-voice flag: several screens
        // (e.g. PDFReaderScreen/EPUBReaderScreen chrome visibility) read the
        // raw `RISHI_UITEST` env var directly rather than UITestBypass.isActive,
        // so the reader toolbar (and the voice button) only pins visible when
        // this is set. The AppDependencies live-voice branch is checked BEFORE
        // the offline-fake branch, so the REAL voice stack still wins.
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launchEnvironment["RISHI_UITEST_LIVE_VOICE"] = "1"
        app.launchEnvironment["RISHI_DEV_BYPASS"] = "1"
        app.launchEnvironment["DEV_BYPASS_SECRET"] = devBypassSecret
        // Optional staging override: forward RISHI_API_URL if the test env set it.
        if let apiURL = ProcessInfo.processInfo.environment["RISHI_API_URL"], !apiURL.isEmpty {
            app.launchEnvironment["RISHI_API_URL"] = apiURL
        }
        app.launch()

        // A fresh UITest install resets OS permissions, so the REAL mic gate
        // surfaces the system microphone prompt when the session starts. Auto-
        // accept it. The monitor fires on the next synthetic interaction, so we
        // do an `app.tap()` right after tapping the voice button below.
        addUIInterruptionMonitor(withDescription: "System permission prompts") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        // 1. Library — wait for the auto-seeded book cell, then open it. The
        //    reader chrome starts visible under the UITest stubs, so the toolbar
        //    (incl. the voice button) is present once the reader opens.
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
        // 2. Tap voice — the REAL presenter runs the FSM: fetch ephemeral key
        //    from the live worker, connect the RealtimeAPIAdapter to OpenAI,
        //    reach .live, present the fullScreenCover and expose "voice.end".
        //    Live connect can take several seconds, so use a generous timeout.
        robustTap(voiceButton)
        // Service the mic-permission interruption monitor (fresh install). The
        // monitor only runs when XCTest processes a synthetic event, so tap.
        usleep(1_500_000)
        app.tap()
        assertReachedLive(
            endButton,
            timeout: 30,
            phase: "FIRST"
        )

        // REPRO ASSERTION 1 — first LIVE session STAYS live for ~5s.
        // With the bug, onEnd auto-fires (trigger=user-button) right after .live,
        // presenter.end() flips isPresenting=false, the cover dismisses, and
        // "voice.end" vanishes within the hold window -> this fails (red).
        assertStaysPresent(
            endButton,
            holdSeconds: 5,
            message: "FIRST live voice session AUTO-ENDED: \"voice.end\" disappeared "
            + "within ~5s with NO user interaction after reaching live. The End button "
            + "action fired on its own (trigger=user-button) and tore the live session "
            + "down — this is the reproduced bug. (Distinct from never connecting: it "
            + "DID appear, then vanished.)"
        )

        // 3. End the first session deliberately and return to the reader.
        robustTap(endButton)
        XCTAssertTrue(
            voiceButton.waitForExistence(timeout: 15),
            "After ending the first session the reader toolbar voice button did not "
            + "reappear — the cover did not dismiss back to the reader."
        )

        // === SECOND SESSION (the user's reported restart) ===
        // 4. Tap voice again — second LIVE session should present and stay.
        robustTap(voiceButton)
        assertReachedLive(
            endButton,
            timeout: 30,
            phase: "SECOND"
        )

        // REPRO ASSERTION 2 — second LIVE session STAYS live for ~5s.
        assertStaysPresent(
            endButton,
            holdSeconds: 5,
            message: "SECOND live voice session AUTO-ENDED: \"voice.end\" disappeared "
            + "within ~5s with NO user interaction after the start->end->start cycle. "
            + "The End button action fired on its own (trigger=user-button) and tore "
            + "the live session down — this is the reproduced bug."
        )
    }

    // MARK: - Helpers

    /// Library -> open the auto-seeded book. Mirrors the proven bootstrap used
    /// by the offline VoiceRestartUITests / read-aloud UITests.
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

    /// Waits for the live session to reach `.live` (the "voice.end" button
    /// appears). If it NEVER appears, fails with a message that is clearly
    /// distinct from the auto-end signature — so the orchestrator can tell a
    /// "never connected" environment problem (simulator / WebRTC / mic
    /// permission / bad secret / worker) apart from the actual auto-teardown
    /// bug (appeared, then vanished — caught by `assertStaysPresent`).
    @MainActor
    private func assertReachedLive(
        _ endButton: XCUIElement,
        timeout: TimeInterval,
        phase: String
    ) {
        XCTAssertTrue(
            endButton.waitForExistence(timeout: timeout),
            "\(phase) live voice session NEVER CONNECTED: \"voice.end\" did not appear "
            + "within \(Int(timeout))s. This is NOT the auto-teardown bug — the session "
            + "never reached live at all. Likely an environment issue: simulator mic "
            + "permission not pre-granted (run `xcrun simctl privacy booted grant "
            + "microphone org.fidexa.rishi`), WebRTC blocked on the simulator, an invalid "
            + "DEV_BYPASS_SECRET, or the worker/OpenAI being unreachable."
        )
    }

    /// Asserts `element` remains present for the entire `holdSeconds` window
    /// without re-tapping anything. Polls roughly twice a second; the moment the
    /// element disappears the test fails with `message` — the signature of the
    /// session auto-ending (the bug). If it survives the whole window the live
    /// session stayed up.
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
