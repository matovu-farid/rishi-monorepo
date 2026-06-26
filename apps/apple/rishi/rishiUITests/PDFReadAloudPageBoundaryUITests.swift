




























import XCTest

final class PDFReadAloudPageBoundaryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    
    
    
    
    
    
    
    
    

    @MainActor
    func testNextButtonCrossesDensePDFPageBoundary() throws {
        try crossViaNextButton(titleContains: "dense", maxPresses: 30)
    }

    
    
    
    
    
    
    
    
    

    @MainActor
    func testWithinPageNextUnderLatentTTSKeepsPlaying() throws {
        let app = launchAndOpenPDF(titleContains: "dense", latentTTS: true)
        let (stop, _) = startSession(app)

        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next-paragraph button missing.")

        let startPage = pageNumber(app) ?? 1

        
        
        for _ in 0..<3 {
            robustTap(next)
            usleep(400_000)
            
            if let p = pageNumber(app), p != startPage { break }
        }

        
        
        
        let pause = app.descendants(matching: .any)
            .matching(identifier: "tts-pause").firstMatch
        if !pause.waitForExistence(timeout: 12) {
            attachHierarchy(app, name: "latent-next-stall")
        }
        XCTAssertTrue(
            pause.exists,
            "After within-page Next under latent TTS, playback never returned to "
            + "Playing (\"tts-pause\" never reappeared) — read-aloud stalled."
        )
        XCTAssertTrue(stop.exists, "Read-aloud session was torn down during within-page Next.")
    }

    

    @MainActor
    func testAutoAdvanceCrossesSamplePDFPageBoundary() throws {
        try crossViaAutoAdvance(titleContains: "sample", timeout: 60)
    }

    @MainActor
    func testAutoAdvanceCrossesDensePDFPageBoundary() throws {
        try crossViaAutoAdvance(titleContains: "dense", timeout: 120)
    }

    

    @MainActor
    private func crossViaNextButton(titleContains: String, maxPresses: Int) throws {
        let app = launchAndOpenPDF(titleContains: titleContains)
        let (stop, _) = startSession(app)

        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next-paragraph button missing.")

        let startPage = try requirePageNumber(app)

        var crossed = false
        for press in 1...maxPresses {
            robustTap(next)
            usleep(1_800_000) 
            if !stop.waitForExistence(timeout: 6) {
                attachHierarchy(app, name: "\(titleContains)-next-halt-\(press)")
            }
            XCTAssertTrue(
                stop.exists,
                "[\(titleContains)] After Next #\(press), the read-aloud session was torn "
                + "down (\"tts-stop\" gone) — narration halted at the page boundary instead "
                + "of continuing onto the next page."
            )
            if let page = pageNumber(app), page > startPage { crossed = true; break }
        }
        if !crossed { attachHierarchy(app, name: "\(titleContains)-next-no-cross") }
        XCTAssertTrue(
            crossed,
            "[\(titleContains)] Pressing Next never advanced the PDF page past \(startPage) — "
            + "read-aloud did not cross the page boundary."
        )
    }

    @MainActor
    private func crossViaAutoAdvance(titleContains: String, timeout: TimeInterval) throws {
        let app = launchAndOpenPDF(titleContains: titleContains)
        let (stop, _) = startSession(app)

        let startPage = try requirePageNumber(app)

        
        
        
        
        let deadline = Date().addingTimeInterval(timeout)
        var crossed = false
        while Date() < deadline {
            if !stop.exists {
                attachHierarchy(app, name: "\(titleContains)-auto-halt")
                XCTFail(
                    "[\(titleContains)] Read-aloud auto-advance tore down the session "
                    + "(\"tts-stop\" gone) before the page advanced past \(startPage) — it "
                    + "halted at the page boundary instead of continuing."
                )
                return
            }
            if let page = pageNumber(app), page > startPage { crossed = true; break }
            usleep(1_500_000)
        }
        if !crossed { attachHierarchy(app, name: "\(titleContains)-auto-no-cross") }
        XCTAssertTrue(
            crossed,
            "[\(titleContains)] Read-aloud auto-advance never moved the PDF page past "
            + "\(startPage) within the timeout — it stopped at the boundary."
        )
    }

    

    
    
    
    
    
    @MainActor
    private func launchAndOpenPDF(titleContains: String, latentTTS: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        if latentTTS {
            
            
            app.launchEnvironment["RISHI_UITEST_TTS_LATENT"] = "1"
        }
        app.launch()

        let cell = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'library-book-cell' AND label CONTAINS[c] %@", titleContains)
        ).firstMatch
        XCTAssertTrue(
            cell.waitForExistence(timeout: 30),
            "Library never showed the seeded '\(titleContains)' PDF cell — auth bypass or PDF seed failed."
        )
        robustTap(cell)
        return app
    }

    
    
    @MainActor
    private func startSession(_ app: XCUIApplication) -> (XCUIElement, XCUIElement) {
        let readAloud = app.descendants(matching: .any)
            .matching(identifier: "reader.toolbar.readAloud").firstMatch
        XCTAssertTrue(
            readAloud.waitForExistence(timeout: 20),
            "Read Aloud toolbar button never appeared — the PDF reader did not open."
        )

        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'tts-play' OR identifier == 'tts-pause'")
        ).firstMatch

        var started = false
        for _ in 0..<6 {
            robustTap(readAloud)
            if toggle.waitForExistence(timeout: 4) { started = true; break }
            turnPageForward(app)
            usleep(1_000_000)
        }
        if !started { attachHierarchy(app, name: "pdf-no-session") }
        XCTAssertTrue(
            started,
            "Read Aloud never started a session on any PDF page — paragraph "
            + "extraction, the entitlement bypass, or the offline TTS source failed."
        )

        let pause = app.descendants(matching: .any)
            .matching(identifier: "tts-pause").firstMatch
        if !pause.waitForExistence(timeout: 25) { attachHierarchy(app, name: "pdf-no-playing") }
        XCTAssertTrue(pause.exists, "PDF passage 0 never reached Playing (no \"tts-pause\").")

        let stop = app.descendants(matching: .any)
            .matching(identifier: "tts-stop").firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Read-aloud controls never appeared.")
        return (stop, toggle)
    }

    

    
    
    @MainActor
    private func pageNumber(_ app: XCUIApplication) -> Int? {
        let indicator = app.descendants(matching: .any)
            .matching(identifier: "reader.pdf.pageIndicator").firstMatch
        guard indicator.exists else { return nil }
        let digits = indicator.label.split(whereSeparator: { !$0.isNumber })
        guard let first = digits.first, let value = Int(first) else { return nil }
        return value
    }

    @MainActor
    private func requirePageNumber(_ app: XCUIApplication) throws -> Int {
        let indicator = app.descendants(matching: .any)
            .matching(identifier: "reader.pdf.pageIndicator").firstMatch
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 10),
            "PDF page indicator (reader.pdf.pageIndicator) never appeared — cannot verify crossing."
        )
        return try XCTUnwrap(pageNumber(app), "Could not parse page number from indicator label.")
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
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    
    
    @MainActor
    private func turnPageForward(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        usleep(600_000)
    }
}
