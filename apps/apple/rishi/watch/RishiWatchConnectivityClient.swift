#if os(watchOS) && canImport(WatchConnectivity)

import Foundation
import RishiWatchShared
import WatchConnectivity

@MainActor
final class RishiWatchConnectivityClient: NSObject, WCSessionDelegate {
    typealias SnapshotHandler = @MainActor (WatchPlaybackSnapshot) -> Void
    typealias AcknowledgementHandler = @MainActor (WatchAcknowledgement) -> Void
    typealias ActivationHandler = @MainActor () -> Void
    typealias TransportFailureHandler = @MainActor (UUID) -> Void

    private let session: WCSession
    let clientID: UUID
    private let defaults: UserDefaults
    private var activationSequence: UInt64
    private var clientSequence: UInt64
    private var handshakeNonce = UUID()
    private var snapshotHandler: SnapshotHandler?
    private var acknowledgementHandler: AcknowledgementHandler?
    private var activationHandler: ActivationHandler?
    private var transportFailureHandler: TransportFailureHandler?
    private var acceptance: WatchSnapshotAcceptance
    private var outstandingCommandRequestID: UUID?

    init(session: WCSession = .default, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        let idKey = "rishi.watch.client.id"
        let sequenceKey = "rishi.watch.activation.sequence"
        let clientSequenceKey = "rishi.watch.client.sequence"
        if let data = defaults.data(forKey: idKey), let id = try? JSONDecoder().decode(UUID.self, from: data) {
            clientID = id
        } else {
            let id = UUID()
            clientID = id
            defaults.set(try? JSONEncoder().encode(id), forKey: idKey)
        }
        activationSequence = (defaults.object(forKey: sequenceKey) as? NSNumber)?.uint64Value ?? 0
        clientSequence = (defaults.object(forKey: clientSequenceKey) as? NSNumber)?.uint64Value ?? 0
        let minimumRedactionRevision = (defaults.object(forKey: "rishi.watch.minimum.redaction.revision") as? NSNumber)?.uint64Value ?? 0
        let minimumAccountGeneration = (defaults.object(forKey: "rishi.watch.minimum.account.generation") as? NSNumber)?.uint64Value ?? 0
        let trustedProcessSessionID: UUID?
        if let data = defaults.data(forKey: "rishi.watch.trusted.process") {
            trustedProcessSessionID = try? JSONDecoder().decode(UUID.self, from: data)
        } else {
            trustedProcessSessionID = nil
        }
        acceptance = WatchSnapshotAcceptance(
            minimumRedactionRevision: minimumRedactionRevision,
            minimumAccountGeneration: minimumAccountGeneration,
            trustedProcessSessionID: trustedProcessSessionID
        )
        super.init()
        session.delegate = self
    }

    func nextClientSequence() -> UInt64 {
        clientSequence &+= 1
        defaults.set(clientSequence, forKey: "rishi.watch.client.sequence")
        return clientSequence
    }

    func start(
        snapshotHandler: @escaping SnapshotHandler,
        acknowledgementHandler: @escaping AcknowledgementHandler,
        activationHandler: @escaping ActivationHandler,
        transportFailureHandler: @escaping TransportFailureHandler
    ) {
        self.snapshotHandler = snapshotHandler
        self.acknowledgementHandler = acknowledgementHandler
        self.activationHandler = activationHandler
        self.transportFailureHandler = transportFailureHandler
        session.activate()
    }

    func requestSnapshot() {
        guard outstandingCommandRequestID == nil else { return }
        acceptance.beginHandshake()
        activationSequence &+= 1
        defaults.set(activationSequence, forKey: "rishi.watch.activation.sequence")
        handshakeNonce = UUID()
        let request = WatchSnapshotRequest(
            watchClientID: clientID,
            handshakeNonce: handshakeNonce,
            activationSequence: activationSequence
        )
        send(request)
    }

    func send(_ envelope: WatchMutatingCommandEnvelope) {
        outstandingCommandRequestID = envelope.requestID
        guard session.isReachable, let data = try? WatchCodec.encode(envelope) else {
            transportFailureHandler?(envelope.requestID)
            return
        }
        session.sendMessageData(data, replyHandler: { [weak self] data in
            Task { @MainActor in
                guard let self,
                      let acknowledgement = try? WatchCodec.decode(WatchAcknowledgement.self, from: data),
                      acknowledgement.requestID == envelope.requestID else { return }
                if acknowledgement.disposition == .terminal,
                   self.outstandingCommandRequestID == envelope.requestID {
                    self.outstandingCommandRequestID = nil
                }
                guard self.accepts(snapshot: acknowledgement.snapshot) else { return }
                self.acknowledgementHandler?(acknowledgement)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.transportFailureHandler?(envelope.requestID) }
        })
    }

    func abandon(requestID: UUID) {
        guard outstandingCommandRequestID == requestID else { return }
        outstandingCommandRequestID = nil
    }

    private func send(_ request: WatchSnapshotRequest) {
        guard session.isReachable, let data = try? WatchCodec.encode(request) else { return }
        session.sendMessageData(data, replyHandler: { [weak self] data in
            Task { @MainActor in
                guard let self, let snapshot = try? WatchCodec.decode(WatchPlaybackSnapshot.self, from: data),
                      snapshot.handshakeNonce == request.handshakeNonce,
                      snapshot.activationSequence == request.activationSequence,
                      self.accepts(snapshot: snapshot) else { return }
                self.snapshotHandler?(snapshot)
            }
        }, errorHandler: { _ in })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.outstandingCommandRequestID == nil else { return }
            self.activationHandler?()
            self.requestSnapshot()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["rishi.watch.snapshot"] as? Data else { return }
        Task { @MainActor [weak self] in
            guard let self, let snapshot = try? WatchCodec.decode(WatchPlaybackSnapshot.self, from: data),
                  snapshot.handshakeNonce == self.handshakeNonce,
                  snapshot.activationSequence == self.activationSequence,
                  self.accepts(snapshot: snapshot) else { return }
            self.snapshotHandler?(snapshot)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.outstandingCommandRequestID == nil else { return }
            self.activationHandler?()
            self.requestSnapshot()
        }
    }

    private func accepts(snapshot: WatchPlaybackSnapshot) -> Bool {
        let accepted = acceptance.accept(
            snapshot,
            expectedHandshakeNonce: handshakeNonce,
            expectedActivationSequence: activationSequence
        )
        guard accepted else { return false }
        if snapshot.redactionTrust == .unverified {
            // A fenced/redacted snapshot means the old command epoch is no
            // longer actionable. Release the transport fence so the Watch
            // model can clear the unknown outcome and start a fresh handshake.
            outstandingCommandRequestID = nil
        }
        defaults.set(acceptance.minimumRedactionRevision, forKey: "rishi.watch.minimum.redaction.revision")
        defaults.set(acceptance.minimumAccountGeneration, forKey: "rishi.watch.minimum.account.generation")
        if let processSessionID = acceptance.trustedProcessSessionID {
            defaults.set(try? JSONEncoder().encode(processSessionID), forKey: "rishi.watch.trusted.process")
        } else {
            defaults.removeObject(forKey: "rishi.watch.trusted.process")
        }
        return true
    }
}

#endif
