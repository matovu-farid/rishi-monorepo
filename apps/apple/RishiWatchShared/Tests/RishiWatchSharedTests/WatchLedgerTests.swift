import Foundation
import XCTest
@testable import RishiWatchShared

final class WatchLedgerTests: XCTestCase {
    func testDuplicateRequestUsesSameReceipt() async throws {
        let ledger = WatchReceiptLedger()
        let envelope = WatchMutatingCommandEnvelope(
            processSessionID: UUID(), watchClientID: UUID(), handshakeNonce: UUID(), activationSequence: 1,
            clientSequence: 1, requestID: UUID(), playbackGeneration: 1, accountGeneration: 1, command: .stop
        )
        let first = try await ledger.reserve(envelope)
        let second = try await ledger.reserve(envelope)
        XCTAssertEqual(first, second)
    }

    func testNewRequestMustAdvanceClientSequence() async throws {
        let ledger = WatchReceiptLedger()
        let clientID = UUID()
        let makeEnvelope: (UInt64) -> WatchMutatingCommandEnvelope = { sequence in
            WatchMutatingCommandEnvelope(
                processSessionID: UUID(), watchClientID: clientID, handshakeNonce: UUID(), activationSequence: 1,
                clientSequence: sequence, requestID: UUID(), playbackGeneration: 1, accountGeneration: 1, command: .stop
            )
        }
        _ = try await ledger.reserve(makeEnvelope(2))
        do {
            _ = try await ledger.reserve(makeEnvelope(1))
            XCTFail("Expected stale sequence rejection")
        } catch {
            XCTAssertEqual(error as? WatchCodecError, .staleSequence)
        }
    }

    func testDuplicateTerminalRequestIsReturnedWithoutReexecution() async throws {
        let ledger = WatchReceiptLedger()
        let envelope = WatchMutatingCommandEnvelope(
            processSessionID: UUID(), watchClientID: UUID(), handshakeNonce: UUID(), activationSequence: 1,
            clientSequence: 1, requestID: UUID(), playbackGeneration: 1, accountGeneration: 1, command: .stop
        )
        _ = try await ledger.reserve(envelope)
        let snapshot = WatchPlaybackSnapshot(
            processSessionID: envelope.processSessionID, handshakeNonce: envelope.handshakeNonce,
            activationSequence: envelope.activationSequence, serverSequence: 1, redactionRevision: 1,
            redactionTrust: .verified, playbackGeneration: 1, accountGeneration: 1, availability: .unavailable,
            validUntil: Date().addingTimeInterval(30)
        )
        let acknowledgement = WatchAcknowledgement(
            requestID: envelope.requestID, disposition: .terminal, accepted: true,
            serverSequence: 1, snapshot: snapshot
        )
        await ledger.settle(requestID: envelope.requestID, acknowledgement: acknowledgement)
        let admission = try await ledger.admit(envelope)
        guard case let .terminal(receipt) = admission else {
            return XCTFail("Expected terminal receipt")
        }
        XCTAssertEqual(receipt.status, .terminal(acknowledgement))
    }

    func testReusedRequestIDWithChangedPayloadIsRejected() async throws {
        let ledger = WatchReceiptLedger()
        let requestID = UUID()
        let clientID = UUID()
        let first = WatchMutatingCommandEnvelope(
            processSessionID: UUID(), watchClientID: clientID, handshakeNonce: UUID(), activationSequence: 1,
            clientSequence: 1, requestID: requestID, playbackGeneration: 1, accountGeneration: 1, command: .stop
        )
        let changed = WatchMutatingCommandEnvelope(
            processSessionID: first.processSessionID, watchClientID: clientID, handshakeNonce: first.handshakeNonce,
            activationSequence: 1, clientSequence: 1, requestID: requestID, playbackGeneration: 1,
            accountGeneration: 1, command: .togglePlayback
        )
        _ = try await ledger.reserve(first)
        do {
            _ = try await ledger.reserve(changed)
            XCTFail("Expected changed duplicate payload rejection")
        } catch {
            XCTAssertEqual(error as? WatchCodecError, .invalidPayload)
        }
    }
}
