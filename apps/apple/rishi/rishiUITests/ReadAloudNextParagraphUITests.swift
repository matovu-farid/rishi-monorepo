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

        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == 'tts-play' OR identifier == 'tts-pause'"
            )
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

        usleep(2_500_000)
        if !toggle.exists {
            robustTap(readAloud)
            XCTAssertTrue(
                toggle.waitForExistence(timeout: 6),
                "Read-aloud could not be restarted on the content page after a "
                    + "straggler page-turn navigation stopped the first session."
            )
        }

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

        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(
            next.waitForExistence(timeout: 5),
            "Next-paragraph button missing."
        )
        robustTap(next)

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

    @MainActor
    func testCrossingPageBoundaryKeepsPlaying() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launch()

        _ = startPlayingSession(app)

        let stop = app.descendants(matching: .any)
            .matching(identifier: "tts-stop").firstMatch
        XCTAssertTrue(
            stop.waitForExistence(timeout: 25),
            "Read-aloud controls never appeared before the page-boundary sweep."
        )

        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(
            next.waitForExistence(timeout: 5),
            "Next-paragraph button missing."
        )

        for press in 1...12 {
            robustTap(next)

            usleep(2_500_000)
            XCTAssertTrue(
                stop.waitForExistence(timeout: 6),
                "After Next #\(press), the read-aloud session was torn down "
                    + "(\"tts-stop\" gone). A page-crossing advance stopped "
                    + "read-aloud: the programmatic page turn's delayed "
                    + "locationDidChange was misread as a user navigation and "
                    + "fired stopReadAloud."
            )
        }
    }

    @MainActor
    private func startPlayingSession(_ app: XCUIApplication) -> (
        XCUIElement, XCUIElement
    ) {
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
            NSPredicate(
                format: "identifier == 'tts-play' OR identifier == 'tts-pause'"
            )
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

    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()
    }

    @MainActor
    private func turnPageForward(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        usleep(600_000)
    }
}
