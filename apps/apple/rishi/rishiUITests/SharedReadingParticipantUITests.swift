import XCTest

final class SharedReadingParticipantUITests: XCTestCase {
    @MainActor
    func testParticipantJoinsAndRejoinsSharedReadingSession() throws {
        let support = SharedReadingTestSupport()
        let app = try support.launch(role: .participant)
        defer { support.resetLocalState(app) }
        try support.login(app, role: .participant)
        let token = try support.waitForInvite()
        support.openSession(app, token: token)
        XCTAssertTrue(app.staticTexts["shared-reading-readers"].waitForExistence(timeout: 60))
        support.assertSessionIsActive(app)
        support.openSharedBook(app)
        try support.publishParticipantReady()
        let receivedSequence = support.waitForSharedProgress(app, atLeast: 2)
        try support.publishParticipantProgress(sequence: receivedSequence)
        XCTAssertTrue(app.buttons["tts-pause"].waitForExistence(timeout: 120))
        try support.publishParticipantPlayback("playing")
        XCTAssertTrue(app.buttons["tts-play"].waitForExistence(timeout: 60))
        try support.publishParticipantPlayback("paused")
        XCTAssertTrue(app.buttons["tts-pause"].waitForExistence(timeout: 120))
        try support.publishParticipantPlayback("resumed")

        // A process restart must recover through the participant's
        // account-scoped active-session list and /rejoin, not by redeeming
        // the original invite again.
        support.restartPreservingLocalState(app)
        support.rejoinActiveSession(app)
        XCTAssertTrue(app.staticTexts["shared-reading-readers"].waitForExistence(timeout: 60))
        support.assertSessionIsActive(app)
        support.openSharedBook(app)
        try support.publishParticipantRejoined(sequence: receivedSequence)

        let leave = app.buttons["shared-reading-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 30))
        support.activate(leave)
        XCTAssertFalse(app.staticTexts["shared-reading-session-title"].waitForExistence(timeout: 10))
        support.rejoinActiveSession(app)
        XCTAssertTrue(app.staticTexts["shared-reading-readers"].waitForExistence(timeout: 60))
        support.assertSessionIsActive(app)
        try support.publishParticipantRejoined(sequence: receivedSequence)
        let rejoinedLeave = app.buttons["shared-reading-leave"]
        XCTAssertTrue(rejoinedLeave.waitForExistence(timeout: 30))
        support.activate(rejoinedLeave)
        XCTAssertFalse(app.staticTexts["shared-reading-session-title"].waitForExistence(timeout: 10))
    }
}
