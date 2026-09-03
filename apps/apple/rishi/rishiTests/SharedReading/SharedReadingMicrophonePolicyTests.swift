import XCTest

final class SharedReadingMicrophonePolicyTests: XCTestCase {
    func testStartsUnmutedAndSpeaksWhenReadingIsPaused() {
        let state = SharedReadingMicrophonePolicyState()
        XCTAssertTrue(state.microphoneEnabled(isTTSPlaying: false))
    }

    func testMuteChoiceWinsInBothModes() {
        let muted = SharedReadingMicrophonePolicy.setMuted(true, in: .init())
        XCTAssertFalse(muted.microphoneEnabled(isTTSPlaying: false))
        XCTAssertFalse(muted.microphoneEnabled(isTTSPlaying: true))
    }

    func testActiveTTSRequiresHoldAndFloor() {
        let base = SharedReadingMicrophonePolicyState()
        XCTAssertFalse(base.microphoneEnabled(isTTSPlaying: true))
        let holding = SharedReadingMicrophonePolicy.setHoldToTalk(true, in: base)
        XCTAssertFalse(holding.microphoneEnabled(isTTSPlaying: true))
        let granted = SharedReadingMicrophonePolicy.setSpeakerFloorGranted(true, in: holding)
        XCTAssertTrue(granted.microphoneEnabled(isTTSPlaying: true))
    }

    func testPauseRestoresUnmutedChoiceAfterTTSFloorEnds() {
        var state = SharedReadingMicrophonePolicyState()
        state.holdToTalk = true
        state.speakerFloorGranted = true
        XCTAssertTrue(state.microphoneEnabled(isTTSPlaying: true))
        XCTAssertTrue(state.microphoneEnabled(isTTSPlaying: false))
    }
}
