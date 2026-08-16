import Foundation

public enum WatchReceiptStatus: Sendable, Equatable {
    case inFlight
    case terminal(WatchAcknowledgement)
}

public struct WatchReceipt: Sendable, Equatable {
    public let requestID: UUID
    public let payloadDigest: Data
    public let status: WatchReceiptStatus
    public let expiresAt: Date

    public init(requestID: UUID, payloadDigest: Data, status: WatchReceiptStatus, expiresAt: Date) {
        self.requestID = requestID
        self.payloadDigest = payloadDigest
        self.status = status
        self.expiresAt = expiresAt
    }
}

public enum WatchReceiptAdmission: Sendable, Equatable {
    case new(WatchReceipt)
    case inFlight(WatchReceipt)
    case terminal(WatchReceipt)
}

/// Process-local receipt ledger. Cross-process replay is fenced by the
/// envelope's processSessionID, so a new phone process never replays an old
/// in-flight command even though its in-memory receipt table is new.
public actor WatchReceiptLedger {
    private var receipts: [UUID: WatchReceipt] = [:]
    private var highestClientSequence: [UUID: UInt64] = [:]
    private let capacity = 32

    public init() {}

    public func reserve(_ envelope: WatchMutatingCommandEnvelope, now: Date = Date()) throws -> WatchReceipt {
        switch try admit(envelope, now: now) {
        case let .new(receipt), let .inFlight(receipt), let .terminal(receipt): return receipt
        }
    }

    public func admit(_ envelope: WatchMutatingCommandEnvelope, now: Date = Date()) throws -> WatchReceiptAdmission {
        purgeExpired(now: now)
        if let existing = receipts[envelope.requestID] {
            guard existing.payloadDigest == (try? WatchCodec.encode(envelope)) else { throw WatchCodecError.invalidPayload }
            switch existing.status {
            case .inFlight: return .inFlight(existing)
            case .terminal: return .terminal(existing)
            }
        }
        guard WatchCodec.isFresh(envelope, now: now) else { throw WatchCodecError.staleCommand }
        guard envelope.clientSequence > (highestClientSequence[envelope.watchClientID] ?? 0) else {
            throw WatchCodecError.staleSequence
        }
        guard receipts.count < capacity else { throw WatchCodecError.capacityExceeded }
        let digest = try WatchCodec.encode(envelope)
        let receipt = WatchReceipt(requestID: envelope.requestID, payloadDigest: digest, status: .inFlight, expiresAt: now.addingTimeInterval(600))
        receipts[envelope.requestID] = receipt
        highestClientSequence[envelope.watchClientID] = max(highestClientSequence[envelope.watchClientID] ?? 0, envelope.clientSequence)
        return .new(receipt)
    }

    public func settle(requestID: UUID, acknowledgement: WatchAcknowledgement) {
        guard let existing = receipts[requestID], case .inFlight = existing.status else { return }
        receipts[requestID] = WatchReceipt(requestID: requestID, payloadDigest: existing.payloadDigest, status: .terminal(acknowledgement), expiresAt: existing.expiresAt)
    }

    public func receipt(for requestID: UUID) -> WatchReceipt? { receipts[requestID] }
    public func highestSequence(for clientID: UUID) -> UInt64 { highestClientSequence[clientID] ?? 0 }
    public func invalidateReceipts() { receipts.removeAll() }
    public func purgeExpired(now: Date = Date()) { receipts = receipts.filter { $0.value.expiresAt > now } }
}
