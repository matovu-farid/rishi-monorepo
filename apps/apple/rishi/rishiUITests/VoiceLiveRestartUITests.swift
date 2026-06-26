


















































import XCTest

final class VoiceLiveRestartUITests: XCTestCase {

    
    private var devBypassSecret: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = false

        
        
        
        guard let secret = ProcessInfo.processInfo.environment["DEV_BYPASS_SECRET"],
              !secret.isEmpty else {
            throw XCTSkip(
                "Set DEV_BYPASS_SECRET to run the live-API voice repro test. "
                + "Without it this test skips (it makes paid OpenAI calls)."
            )
        }
        devBypassSecret = secret
    }

    
    @MainActor
    func testLiveVoiceSessionStaysLiveAcrossRestart() throws {
        let app = XCUIApplication()
        
        
        
        
        
        
        
        
        
        
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launchEnvironment["RISHI_UITEST_LIVE_VOICE"] = "1"
        app.launchEnvironment["RISHI_DEV_BYPASS"] = "1"
        app.launchEnvironment["DEV_BYPASS_SECRET"] = devBypassSecret
        
        if let apiURL = ProcessInfo.processInfo.environment["RISHI_API_URL"], !apiURL.isEmpty {
            app.launchEnvironment["RISHI_API_URL"] = apiURL
        }
        app.launch()

        
        
        
        
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

        
        
        
        
        
        robustTap(voiceButton)
        
        
        usleep(1_500_000)
        app.tap()
        assertReachedLive(
            endButton,
            timeout: 30,
            phase: "FIRST"
        )

        
        
        
        
        assertStaysPresent(
            endButton,
            holdSeconds: 5,
            message: "FIRST live voice session AUTO-ENDED: \"voice.end\" disappeared "
            + "within ~5s with NO user interaction after reaching live. The End button "
            + "action fired on its own (trigger=user-button) and tore the live session "
            + "down — this is the reproduced bug. (Distinct from never connecting: it "
            + "DID appear, then vanished.)"
        )

        
        robustTap(endButton)
        XCTAssertTrue(
            voiceButton.waitForExistence(timeout: 15),
            "After ending the first session the reader toolbar voice button did not "
            + "reappear — the cover did not dismiss back to the reader."
        )

        
        
        robustTap(voiceButton)
        assertReachedLive(
            endButton,
            timeout: 30,
            phase: "SECOND"
        )

        
        assertStaysPresent(
            endButton,
            holdSeconds: 5,
            message: "SECOND live voice session AUTO-ENDED: \"voice.end\" disappeared "
            + "within ~5s with NO user interaction after the start->end->start cycle. "
            + "The End button action fired on its own (trigger=user-button) and tore "
            + "the live session down — this is the reproduced bug."
        )
    }

    

    
    
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

    
    
    
    
    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
