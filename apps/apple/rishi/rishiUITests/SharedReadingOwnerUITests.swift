import XCTest

final class SharedReadingOwnerUITests: XCTestCase {
    @MainActor
    func testOwnerCreatesAndStartsSharedReadingSession() throws {
        let support = SharedReadingTestSupport()
        support.recordStage("owner.test-begin")
        let app = try support.launch(role: .owner)
        defer { support.resetLocalState(app) }
        try support.login(app, role: .owner)
        XCTAssertFalse(
            app.buttons["data-use-consent-allow"].exists,
            "A real-auth shared-reading owner must complete consent before waiting for inbound sync"
        )
        support.waitForProvisionedBook(app)
        support.recordStage("owner.fixture-visible")
        _ = try support.createReadingLink(app)
        support.recordStage("owner.invite-created")
        XCTAssertTrue(app.staticTexts["shared-reading-session-title"].waitForExistence(timeout: 60))
        let start = app.buttons["shared-reading-start"]
        if start.waitForExistence(timeout: 20) { support.activate(start) }
        support.assertSessionIsActive(app)
        try support.waitForParticipantReady()
        support.openSharedBook(app)
        support.waitForSharedProgress(app, atLeast: 1)
        support.advanceSharedReader(app)
        support.waitForSharedProgress(app, atLeast: 2)
        try support.waitForParticipantProgress()
        let readAloud = app.buttons["reader.toolbar.readAloud"]
        XCTAssertTrue(readAloud.waitForExistence(timeout: 30))
        support.activate(readAloud)
        let play = app.buttons["tts-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        support.activate(play)
        XCTAssertTrue(app.buttons["tts-pause"].waitForExistence(timeout: 120))
        try support.waitForParticipantPlayback("playing")
        support.activate(app.buttons["tts-pause"])
        XCTAssertTrue(app.buttons["tts-play"].waitForExistence(timeout: 30))
        try support.waitForParticipantPlayback("paused")
        support.activate(app.buttons["tts-play"])
        XCTAssertTrue(app.buttons["tts-pause"].waitForExistence(timeout: 120))
        try support.waitForParticipantPlayback("resumed")
        try support.waitForParticipantRejoined()
    }
}
