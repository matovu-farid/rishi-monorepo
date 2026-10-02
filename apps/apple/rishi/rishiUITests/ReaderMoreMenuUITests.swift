import XCTest

final class ReaderMoreMenuUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReadAloudAndVoiceChatAreTopLevelAndReaderOptionsRemainInMore() throws {
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

        let readAloud = app.buttons["reader.toolbar.readAloud"]
        let voiceChat = app.buttons["reader.toolbar.voice"]
        XCTAssertTrue(
            readAloud.waitForExistence(timeout: 15),
            "Read Aloud should be available directly in the reader toolbar."
        )
        XCTAssertTrue(
            voiceChat.waitForExistence(timeout: 15),
            "Voice Chat should be available directly in the reader toolbar."
        )
        XCTAssertTrue(readAloud.isHittable)
        XCTAssertTrue(voiceChat.isHittable)

        let more = app.buttons["reader.toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Reader More button missing.")
        robustTap(more)

        XCTAssertTrue(
            app.buttons["reader.toolbar.typography"].waitForExistence(timeout: 5),
            "Text Size should remain in the More menu."
        )
        XCTAssertTrue(
            app.buttons["reader.toolbar.theme"].waitForExistence(timeout: 5),
            "Appearance should remain in the More menu."
        )
    }

    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
