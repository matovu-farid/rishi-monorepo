import Foundation
import XCTest
@testable import RishiWatchShared

final class WatchProtocolTests: XCTestCase {
    func testCommandRoundTripsWithHandshakeFields() throws {
        let envelope = WatchMutatingCommandEnvelope(
            processSessionID: UUID(), watchClientID: UUID(), handshakeNonce: UUID(), activationSequence: 3,
            clientSequence: 8, requestID: UUID(), playbackGeneration: 2, accountGeneration: 4,
            command: .setPlaybackRate(1.25)
        )
        let decoded = try WatchCodec.decode(WatchMutatingCommandEnvelope.self, from: WatchCodec.encode(envelope))
        XCTAssertEqual(decoded, envelope)
    }

    func testSnapshotClampsProgressAndTruncatesText() {
        let snapshot = WatchPlaybackSnapshot(
            processSessionID: UUID(), handshakeNonce: UUID(), activationSequence: 1, serverSequence: 1,
            redactionRevision: 1, redactionTrust: .verified, playbackGeneration: 1, accountGeneration: 1,
            availability: .active, title: String(repeating: "x", count: 300), progress: 2,
            progressScope: .book, validUntil: Date()
        )
        XCTAssertEqual(snapshot.progress, 1)
        XCTAssertEqual(snapshot.title?.count, WatchProtocolConstants.maximumTextLength)
    }

    func testFutureCommandIsNotFresh() {
        let envelope = WatchMutatingCommandEnvelope(
            processSessionID: UUID(), watchClientID: UUID(), handshakeNonce: UUID(), activationSequence: 1,
            clientSequence: 1, requestID: UUID(), issuedAt: Date().addingTimeInterval(10),
            playbackGeneration: 1, accountGeneration: 1, command: .stop
        )
        XCTAssertFalse(WatchCodec.isFresh(envelope))
    }

    func testUnsupportedProtocolVersionIsRejected() throws {
        let request = WatchSnapshotRequest(watchClientID: UUID(), handshakeNonce: UUID(), activationSequence: 1)
        var data = try WatchCodec.encode(request)
        data = Data(data.map { $0 })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["protocolVersion"] = WatchProtocolConstants.currentVersion + 1
        let future = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try WatchCodec.decode(WatchSnapshotRequest.self, from: future)) { error in
            XCTAssertEqual(error as? WatchCodecError, .unsupportedVersion)
        }
    }

    func testFreshnessRejectsOlderRedactionAndAccountEpochs() {
        let nonce = UUID()
        let process = UUID()
        var acceptance = WatchSnapshotAcceptance(
            minimumRedactionRevision: 5,
            minimumAccountGeneration: 3,
            trustedProcessSessionID: process,
            hasFreshHandshake: true
        )
        let stale = WatchPlaybackSnapshot(
            processSessionID: process, handshakeNonce: nonce, activationSequence: 1,
            serverSequence: 1, redactionRevision: 4, redactionTrust: .verified,
            playbackGeneration: 1, accountGeneration: 2, availability: .active,
            validUntil: Date().addingTimeInterval(30)
        )
        let accepted = acceptance.accept(
            stale,
            expectedHandshakeNonce: nonce,
            expectedActivationSequence: 1
        )
        XCTAssertFalse(accepted)
    }

    func testFreshHandshakeAllowsNewProcessAndUnverifiedClearsTrust() {
        let oldProcess = UUID()
        let newProcess = UUID()
        let newNonce = UUID()
        var acceptance = WatchSnapshotAcceptance(
            minimumRedactionRevision: 2,
            minimumAccountGeneration: 1,
            trustedProcessSessionID: oldProcess,
            hasFreshHandshake: true
        )
        let changedProcess = WatchPlaybackSnapshot(
            processSessionID: newProcess, handshakeNonce: newNonce, activationSequence: 2,
            serverSequence: 1, redactionRevision: 3, redactionTrust: .verified,
            playbackGeneration: 1, accountGeneration: 1, availability: .active,
            validUntil: Date().addingTimeInterval(30)
        )
        XCTAssertFalse(acceptance.accept(
            changedProcess,
            expectedHandshakeNonce: newNonce,
            expectedActivationSequence: 2
        ))
        acceptance.beginHandshake()
        XCTAssertTrue(acceptance.accept(
            changedProcess,
            expectedHandshakeNonce: newNonce,
            expectedActivationSequence: 2
        ))
        let redacted = WatchPlaybackSnapshot(
            processSessionID: newProcess, handshakeNonce: newNonce, activationSequence: 2,
            serverSequence: 2, redactionRevision: 4, redactionTrust: .unverified,
            playbackGeneration: 0, accountGeneration: 0, availability: .unavailable,
            validUntil: Date().addingTimeInterval(15)
        )
        XCTAssertTrue(acceptance.accept(
            redacted,
            expectedHandshakeNonce: newNonce,
            expectedActivationSequence: 2
        ))
        XCTAssertFalse(acceptance.hasFreshHandshake)
    }
}
