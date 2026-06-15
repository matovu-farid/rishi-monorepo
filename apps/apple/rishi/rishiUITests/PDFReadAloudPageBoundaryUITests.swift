//
//  PDFReadAloudPageBoundaryUITests.swift
//  rishiUITests
//
//  PDF analog of ReadAloudNextParagraphUITests.testCrossingPageBoundaryKeepsPlaying
//  (the EPUB "Bug 4" guard). Read-aloud must continue onto the next page when it
//  reaches the last paragraph of a page, rather than HALTING at the boundary.
//
//  Run against TWO fixtures, both asserting the live PDF PAGE NUMBER actually
//  advances (proof narration moved onto the next page, not merely that the
//  session survived):
//    - the seeded sample.pdf (light, 3-page tour), and
//    - a synthesized TEXT-DENSE PDF ("uitest-dense", seeded under RISHI_UITEST).
//
//  The dense fixture matters: the real-app halt only reproduces on text-dense
//  pages, whose off-main `selectionsByLine` extraction is slow enough to race
//  the main-thread PDFView reading the SAME PDFDocument and return empty text
//  (PDFKit's PDFDocument is not safe for concurrent access). The light sample
//  page is too fast to overlap. We cannot ship the copyrighted real book that
//  surfaced this (Velleman's "How to Prove It"), so UITestDensePDF synthesizes a
//  comparably dense PDF. The fix gives read-aloud its own PDFDocument instance.
//
//  Crossing modes:
//    - …CrossesPDFPageBoundary: press Next until the page advances.
//    - …AutoAdvanceCrosses…: let playback auto-advance to the end of the page
//      and confirm it crosses on its own (the user's literal symptom — "let it
//      read to the end and it just stops").
//

import XCTest

final class PDFReadAloudPageBoundaryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Next-button crossing
    //
    // Only the DENSE fixture is used for the Next-button test. The light
    // sample.pdf has ~2 short paragraphs on page 1, so auto-advance crosses the
    // boundary within a few seconds — before the test can read the start page or
    // press Next — making a "press Next to cross" assertion inherently racy.
    // sample.pdf crossing is covered by the auto-advance test below; the dense
    // fixture (many paragraphs per page) is where pressing Next deterministically
    // drives the crossing.

    @MainActor
    func testNextButtonCrossesDensePDFPageBoundary() throws {
        try crossViaNextButton(titleContains: "dense", maxPresses: 30)
    }

    // MARK: - Within-page Next under latent (production-like) TTS
    //
    // Reproduces the user's actual report: pressing Next stops the audio even
    // WITHIN a page, while auto-advance keeps playing. Uses the latent + cached
    // TTS fixture (RISHI_UITEST_TTS_LATENT) so prewarm-vs-replay timing matches
    // production. `next()` (jump) cancels the in-flight prewarm of the target
    // paragraph and re-requests it; under real synthesis latency the audio
    // halts. We press Next several times within the dense page (well short of
    // the page boundary) and require playback to come back to Playing.

    @MainActor
    func testWithinPageNextUnderLatentTTSKeepsPlaying() throws {
        let app = launchAndOpenPDF(titleContains: "dense", latentTTS: true)
        let (stop, _) = startSession(app)

        let next = app.descendants(matching: .any)
            .matching(identifier: "tts-next-paragraph").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next-paragraph button missing.")

        let startPage = pageNumber(app) ?? 1

        // Press Next a few times within the page (the dense page has many
        // paragraphs, so this stays well short of a page boundary).
        for _ in 0..<3 {
            robustTap(next)
            usleep(400_000)
            // Stay within the page — abort if we somehow crossed (not the point).
            if let p = pageNumber(app), p != startPage { break }
        }

        // The audio must come back to Playing. A within-page Next that stalls
        // leaves the toggle on "tts-play" (loading) and "tts-pause" never
        // reappears — the reported "audio stops".
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

    // MARK: - Auto-advance crossing (the user's literal symptom)

    @MainActor
    func testAutoAdvanceCrossesSamplePDFPageBoundary() throws {
        try crossViaAutoAdvance(titleContains: "sample", timeout: 60)
    }

    @MainActor
    func testAutoAdvanceCrossesDensePDFPageBoundary() throws {
        try crossViaAutoAdvance(titleContains: "dense", timeout: 120)
    }

    // MARK: - Shared crossing flows

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
            usleep(1_800_000) // passage switch + any delayed page-turn callback
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

        // Do NOT press Next. Let playback auto-advance through the page's
        // paragraphs; when it finishes the last one it must cross onto the next
        // page on its own. Poll the page number while requiring the session to
        // stay alive: a boundary halt tears down "tts-stop" before crossing.
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

    // MARK: - Bootstrap

    /// Launches under RISHI_UITEST and opens the seeded PDF whose library cell
    /// label contains `titleContains` ("sample" -> sample.pdf, "dense" ->
    /// the synthesized dense PDF). Under RISHI_UITEST the reader opens at page 1
    /// (position restore is skipped), so every test starts with a real page
    /// boundary ahead — no rewind needed.
    @MainActor
    private func launchAndOpenPDF(titleContains: String, latentTTS: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        if latentTTS {
            // Wrap the fixture TTS in a real cache + add a synthesis delay so the
            // prewarm-vs-Next timing matches the production network path.
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

    /// Starts a Read Aloud session and returns once playback reaches Playing.
    /// Returns the stable "tts-stop" element and the play/pause toggle.
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

    // MARK: - Helpers

    /// Reads the live page number from the "reader.pdf.pageIndicator" label
    /// ("Page X of Y"); nil if the indicator or a leading integer is absent.
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

    /// Coordinate tap — SwiftUI buttons in overlays often report isHittable=false;
    /// a coordinate tap does no hittability check and is reliable for a visible
    /// element. Settles briefly first so the frame is stable.
    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Turns the PDF forward one page by tapping the right region, which
    /// PDFReaderScreen.onTap maps to `viewModel.seek(toPage: pageIndex + 1)`.
    @MainActor
    private func turnPageForward(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        usleep(600_000)
    }
}
