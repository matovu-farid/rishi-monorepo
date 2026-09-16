





































import XCTest

final class VoiceRestartUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    
    @MainActor
    func testVoiceSessionStaysLiveAcrossRestart() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launch()

        
        
        
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
        XCTAssertTrue(
            endButton.waitForExistence(timeout: 20),
            "First voice session never presented — \"voice.end\" did not appear. "
            + "The offline fakes failed to reach .live, or the session auto-ended "
            + "before the surface mounted."
        )

        
        
        
        
        assertStaysPresent(
            endButton,
            holdSeconds: 3,
            message: "FIRST voice session auto-ended: \"voice.end\" disappeared within "
            + "~3s with no user interaction. The End button action fired on its own "
            + "(trigger=user-button) and tore the session down."
        )

        
        robustTap(endButton)
        XCTAssertTrue(
            voiceButton.waitForExistence(timeout: 15),
            "After ending the first session the reader toolbar voice button did not "
            + "reappear — the cover did not dismiss back to the reader."
        )

        
        
        robustTap(voiceButton)
        XCTAssertTrue(
            endButton.waitForExistence(timeout: 20),
            "Second voice session never presented — \"voice.end\" did not appear after "
            + "restarting voice. The session failed to reach .live or auto-ended before "
            + "the surface mounted."
        )

        
        
        assertStaysPresent(
            endButton,
            holdSeconds: 3,
            message: "SECOND voice session auto-ended: \"voice.end\" disappeared within "
            + "~3s with no user interaction after the start->end->start cycle. The End "
            + "button action fired on its own (trigger=user-button) and tore the session down."
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
