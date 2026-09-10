import XCTest

final class PDFReadAloudPageBoundaryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNextButtonCrossesSamplePDFPageBoundary() throws {
        try crossViaNextButton(titleContains: "sample", maxPresses: 30)
    }

    @MainActor
    func testWithinPageNextUnderLatentTTSKeepsPlaying() throws {
        let app = launchAndOpenPDF(titleContains: "sample", latentTTS: true)
        _ = startSession(app)

        let next = app.buttons
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(
            next.waitForExistence(timeout: 5),
            "Next-paragraph button missing."
        )

        let startPage = pageNumber(app) ?? 1

        for _ in 0..<3 {
            robustTap(next)
            usleep(400_000)

            if let p = pageNumber(app), p != startPage { break }
        }

        let pause = waitForButton(app, identifier: "tts-pause", timeout: 12)
        if pause == nil {
            attachHierarchy(app, name: "latent-next-stall")
        }
        XCTAssertTrue(
            pause != nil,
            "After within-page Next under latent TTS, playback never returned to "
                + "Playing (\"tts-pause\" never reappeared) — read-aloud stalled."
        )
        XCTAssertTrue(
            waitForButton(app, identifier: "tts-stop", timeout: 2) != nil,
            "Read-aloud session was torn down during within-page Next."
        )
    }

    @MainActor
    func testAutoAdvanceCrossesSamplePDFPageBoundary() throws {
        try crossViaAutoAdvance(titleContains: "sample", timeout: 60)
    }

    @MainActor
    private func crossViaNextButton(titleContains: String, maxPresses: Int)
        throws
    {
        let app = launchAndOpenPDF(titleContains: titleContains)
        _ = startSession(app)

        let next = app.buttons
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(
            next.waitForExistence(timeout: 5),
            "Next-paragraph button missing."
        )

        let startPage = try requirePageNumber(app)

        var crossed = false
        for press in 1...maxPresses {
            robustTap(next)
            usleep(1_800_000)
            if waitForButton(app, identifier: "tts-stop", timeout: 6) == nil {
                attachHierarchy(
                    app,
                    name: "\(titleContains)-next-halt-\(press)"
                )
            }
            XCTAssertTrue(
                waitForButton(app, identifier: "tts-stop", timeout: 0.1) != nil,
                "[\(titleContains)] After Next #\(press), the read-aloud session was torn "
                    + "down (\"tts-stop\" gone) — narration halted at the page boundary instead "
                    + "of continuing onto the next page."
            )
            if let page = pageNumber(app), page > startPage {
                crossed = true
                break
            }
        }
        if !crossed {
            attachHierarchy(app, name: "\(titleContains)-next-no-cross")
        }
        XCTAssertTrue(
            crossed,
            "[\(titleContains)] Pressing Next never advanced the PDF page past \(startPage) — "
                + "read-aloud did not cross the page boundary."
        )
    }

    @MainActor
    private func crossViaAutoAdvance(
        titleContains: String,
        timeout: TimeInterval
    ) throws {
        let app = launchAndOpenPDF(titleContains: titleContains, autoplayTTS: true)
        // Capture the baseline before the one-second UI-test TTS script can
        // finish the first sentence and move the PDF to a later page.
        let startPage = try requirePageNumber(app)
        _ = startSession(app)

        let deadline = Date().addingTimeInterval(timeout)
        var crossed = false
        while Date() < deadline {
            if waitForButton(app, identifier: "tts-stop", timeout: 0.5) == nil {
                attachHierarchy(app, name: "\(titleContains)-auto-halt")
                XCTFail(
                    "[\(titleContains)] Read-aloud auto-advance tore down the session "
                        + "(\"tts-stop\" gone) before the page advanced past \(startPage) — it "
                        + "halted at the page boundary instead of continuing."
                )
                return
            }
            if let page = pageNumber(app), page > startPage {
                crossed = true
                break
            }
            usleep(1_500_000)
        }
        if !crossed {
            attachHierarchy(app, name: "\(titleContains)-auto-no-cross")
        }
        XCTAssertTrue(
            crossed,
            "[\(titleContains)] Read-aloud auto-advance never moved the PDF page past "
                + "\(startPage) within the timeout — it stopped at the boundary."
        )
    }

    @MainActor
    private func launchAndOpenPDF(
        titleContains: String,
        latentTTS: Bool = false,
        autoplayTTS: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        if latentTTS {

            app.launchEnvironment["RISHI_UITEST_TTS_LATENT"] = "1"
        }
        if autoplayTTS {
            app.launchEnvironment["RISHI_UITEST_TTS_AUTOPLAY"] = "1"
        }
        app.launch()

        let cell = app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "identifier == 'library-book-cell' AND value == 'pdf' AND label CONTAINS[c] %@",
                titleContains
            )
        ).firstMatch
        XCTAssertTrue(
            cell.waitForExistence(timeout: 30),
            "Library never showed the seeded '\(titleContains)' PDF cell — auth bypass or PDF seed failed."
        )
        robustTap(cell)
        return app
    }

    @MainActor
    private func startSession(_ app: XCUIApplication) -> (
        XCUIElement, XCUIElement
    ) {
        let readAloud = app.buttons
            .matching(identifier: "reader.toolbar.readAloud").firstMatch
        XCTAssertTrue(
            readAloud.waitForExistence(timeout: 20),
            "Read Aloud toolbar button never appeared — the PDF reader did not open."
        )

        let toggle = app.buttons.matching(
            NSPredicate(
                format: "identifier == 'tts-play' OR identifier == 'tts-pause'"
            )
        ).firstMatch

        var started = false
        for _ in 0..<6 {
            robustTap(readAloud)
            if toggle.waitForExistence(timeout: 4) {
                started = true
                break
            }
            turnPageForward(app)
            usleep(1_000_000)
        }
        if !started { attachHierarchy(app, name: "pdf-no-session") }
        XCTAssertTrue(
            started,
            "Read Aloud never started a session on any PDF page — paragraph "
                + "extraction, the entitlement bypass, or the offline TTS source failed."
        )

        let pause = waitForButton(app, identifier: "tts-pause", timeout: 25)
        if pause == nil {
            attachHierarchy(app, name: "pdf-no-playing")
        }
        XCTAssertTrue(
            pause != nil,
            "PDF passage 0 never reached Playing (no \"tts-pause\")."
        )

        let stop = waitForButton(app, identifier: "tts-stop", timeout: 10)
        XCTAssertTrue(
            stop != nil,
            "Read-aloud controls never appeared."
        )
        return (stop ?? app.buttons.matching(identifier: "tts-stop").firstMatch, toggle)
    }

    @MainActor
    private func waitForButton(
        _ app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // SwiftUI replaces the audio overlay's accessibility subtree when
            // playback becomes live. Rebuild the query on each poll so a
            // query created before that replacement cannot remain stale.
            let button = app.buttons.matching(identifier: identifier).firstMatch
            if button.exists { return button }
            let remaining = max(0.1, min(1.0, deadline.timeIntervalSinceNow))
            if button.waitForExistence(timeout: remaining) { return button }
        }
        return nil
    }

    @MainActor
    private func pageNumber(_ app: XCUIApplication) -> Int? {
        let indicator = app.descendants(matching: .any)
            .matching(identifier: "reader.pdf.pageIndicator").firstMatch
        guard indicator.exists else { return nil }
        let digits = indicator.label.split(whereSeparator: { !$0.isNumber })
        guard let first = digits.first, let value = Int(first) else {
            return nil
        }
        return value
    }

    @MainActor
    private func requirePageNumber(_ app: XCUIApplication) throws -> Int {
        let indicator = app.descendants(matching: .any)
            .matching(identifier: "reader.pdf.pageIndicator").firstMatch
        if !indicator.waitForExistence(timeout: 10) {
            attachHierarchy(app, name: "pdf-missing-page-indicator")
        }
        XCTAssertTrue(
            indicator.exists,
            "PDF page indicator (reader.pdf.pageIndicator) never appeared — cannot verify crossing."
        )
        return try XCTUnwrap(
            pageNumber(app),
            "Could not parse page number from indicator label."
        )
    }

    @MainActor
    private func attachHierarchy(_ app: XCUIApplication, name: String) {
        let snap = XCTAttachment(string: app.debugDescription)
        snap.name = name
        snap.lifetime = .keepAlways
        add(snap)
    }

    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.tap()
    }

    @MainActor
    private func turnPageForward(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        usleep(600_000)
    }
}
