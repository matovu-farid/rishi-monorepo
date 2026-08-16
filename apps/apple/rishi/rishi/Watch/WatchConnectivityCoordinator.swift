#if os(iOS) && canImport(WatchConnectivity)

import Foundation
import RishiWatchShared
import WatchConnectivity

@MainActor
protocol WatchConnectivityCommandHandling: AnyObject {
    func watchSnapshot(request: WatchSnapshotRequest) -> WatchPlaybackSnapshot
    func handleWatchCommand(_ envelope: WatchMutatingCommandEnvelope) async -> WatchAcknowledgement
}

@MainActor
final class WatchConnectivityCoordinator {
    private let session: WCSession
    private let processSessionID = UUID()
    private weak var handler: (any WatchConnectivityCommandHandling)?
    private var activationInFlight = false
    private var serverSequence: UInt64 = 0
    private var lastSnapshot: WatchPlaybackSnapshot?
    private var lastSnapshotRequest: WatchSnapshotRequest?
    private var snapshotRefreshTask: Task<Void, Never>?
    private var pendingContextSnapshot: WatchPlaybackSnapshot?
    private var pendingContextClear = false

    private enum CommandOutcome: Sendable {
        case completed(WatchAcknowledgement)
        case timedOut
    }

    private final class CommandOutcomeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasWinner = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !hasWinner else { return false }
            hasWinner = true
            return true
        }
    }

    init(session: WCSession = .default, handler: (any WatchConnectivityCommandHandling)? = nil) {
        self.session = session
        self.handler = handler
    }

    func attach(handler: any WatchConnectivityCommandHandling) {
        self.handler = handler
        activateIfNeeded()
    }

    func activateIfNeeded() {
        guard !activationInFlight else { return }
        activationInFlight = true
        session.activate()
    }

    func didCompleteActivation() {
        activationInFlight = false
        flushPendingContext()
        if lastSnapshot != nil, session.isReachable {
            scheduleSnapshotRefresh()
        }
    }

    func publish(snapshot: WatchPlaybackSnapshot) {
        guard canPublish(snapshot) else { return }
        lastSnapshot = snapshot
        pendingContextClear = false
        publishContext(snapshot)
    }

    func clearPublishedSnapshot() {
        lastSnapshot = nil
        lastSnapshotRequest = nil
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        pendingContextSnapshot = nil
        pendingContextClear = true
        flushPendingContext()
    }

    func receiveSnapshotRequest(_ data: Data, reply: @escaping (Data) -> Void) {
        Task { @MainActor [weak self] in
            guard let request = try? WatchCodec.decode(WatchSnapshotRequest.self, from: data) else { return }
            guard let self else { return }
            guard let handler else {
                reply((try? WatchCodec.encode(unavailableSnapshot(request: request))) ?? Data())
                return
            }
            let snapshot = handler.watchSnapshot(request: request)
            let wasRejected: Bool
            if case let .unknown(rawValue) = snapshot.availability {
                wasRejected = rawValue == WatchRejectionReason.staleProcess.rawValue
            } else {
                wasRejected = false
            }
            if !wasRejected {
                lastSnapshotRequest = request
            }
            let encoded = (try? WatchCodec.encode(snapshot)) ?? Data()
            if self.canPublish(snapshot) {
                self.lastSnapshot = snapshot
                self.pendingContextClear = false
                self.publishContext(snapshot)
                self.scheduleSnapshotRefresh()
            }
            reply(encoded)
        }
    }

    func receiveCommand(_ data: Data, reply: @escaping (Data) -> Void) {
        Task { @MainActor [weak self] in
            guard let envelope = try? WatchCodec.decode(WatchMutatingCommandEnvelope.self, from: data) else { return }
            guard let self else { return }
            guard let handler else {
                let snapshot = unavailableSnapshot(
                    request: WatchSnapshotRequest(
                        watchClientID: envelope.watchClientID,
                        handshakeNonce: envelope.handshakeNonce,
                        activationSequence: envelope.activationSequence
                    )
                )
                let acknowledgement = WatchAcknowledgement(
                    requestID: envelope.requestID,
                    disposition: .deferred,
                    accepted: false,
                    rejectionReason: .busy,
                    serverSequence: serverSequence,
                    snapshot: snapshot
                )
                reply((try? WatchCodec.encode(acknowledgement)) ?? Data())
                return
            }
            let commandTask = Task { @MainActor in
                await handler.handleWatchCommand(envelope)
            }
            let gate = CommandOutcomeGate()
            let outcome = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    let value = await commandTask.value
                    guard gate.claim() else { return }
                    continuation.resume(returning: CommandOutcome.completed(value))
                }
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard gate.claim() else { return }
                    continuation.resume(returning: CommandOutcome.timedOut)
                }
            }
            let acknowledgement: WatchAcknowledgement
            switch outcome {
            case let .completed(value):
                acknowledgement = value
                if canPublish(value.snapshot) {
                    lastSnapshot = value.snapshot
                }
            case .timedOut:
                let snapshot = lastSnapshot ?? handler.watchSnapshot(
                    request: WatchSnapshotRequest(
                        watchClientID: envelope.watchClientID,
                        handshakeNonce: envelope.handshakeNonce,
                        activationSequence: envelope.activationSequence
                    )
                )
                acknowledgement = WatchAcknowledgement(
                    requestID: envelope.requestID,
                    disposition: .deferred,
                    accepted: false,
                    rejectionReason: .busy,
                    serverSequence: snapshot.serverSequence,
                    snapshot: snapshot
                )
            }
            let encoded = (try? WatchCodec.encode(acknowledgement)) ?? Data()
            if canPublish(acknowledgement.snapshot) {
                lastSnapshot = acknowledgement.snapshot
                publishContext(acknowledgement.snapshot)
            }
            reply(encoded)
        }
    }

    private func canPublish(_ snapshot: WatchPlaybackSnapshot) -> Bool {
        guard let current = lastSnapshot else { return true }
        if snapshot.redactionTrust == .unverified {
            return true
        }
        if current.redactionTrust == .unverified {
            return snapshot.redactionRevision > current.redactionRevision
        }
        return snapshot.processSessionID == current.processSessionID
            && snapshot.accountGeneration == current.accountGeneration
            && snapshot.redactionRevision >= current.redactionRevision
    }

    private func publishContext(_ snapshot: WatchPlaybackSnapshot) {
        guard let data = try? WatchCodec.encode(snapshot) else {
            pendingContextSnapshot = snapshot
            return
        }
        do {
            try session.updateApplicationContext(["rishi.watch.snapshot": data])
            pendingContextSnapshot = nil
            pendingContextClear = false
        } catch {
            pendingContextSnapshot = snapshot
            pendingContextClear = false
        }
    }

    private func flushPendingContext() {
        if let snapshot = pendingContextSnapshot {
            publishContext(snapshot)
            return
        }
        guard pendingContextClear else { return }
        do {
            try session.updateApplicationContext([:])
            pendingContextClear = false
        } catch {
            pendingContextClear = true
        }
    }

    private func scheduleSnapshotRefresh() {
        guard snapshotRefreshTask == nil else { return }
        snapshotRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else {
                    self.snapshotRefreshTask = nil
                    return
                }
                guard self.session.isReachable,
                      let handler = self.handler,
                      let request = self.lastSnapshotRequest else {
                    self.snapshotRefreshTask = nil
                    return
                }
                let snapshot = handler.watchSnapshot(request: request)
                guard self.canPublish(snapshot) else { continue }
                self.lastSnapshot = snapshot
                self.publishContext(snapshot)
            }
        }
    }

    private func unavailableSnapshot(request: WatchSnapshotRequest) -> WatchPlaybackSnapshot {
        serverSequence &+= 1
        return WatchPlaybackSnapshot(
            processSessionID: processSessionID,
            handshakeNonce: request.handshakeNonce,
            activationSequence: request.activationSequence,
            serverSequence: serverSequence,
            redactionRevision: 0,
            redactionTrust: .unverified,
            playbackGeneration: 0,
            accountGeneration: 0,
            availability: .unavailable,
            validUntil: Date().addingTimeInterval(15)
        )
    }
}

final class WatchConnectivityDelegateAdapter: NSObject, WCSessionDelegate {
    private let coordinator: WatchConnectivityCoordinator

    private final class ReplyHandlerBox: @unchecked Sendable {
        private let handler: (Data) -> Void

        init(_ handler: @escaping (Data) -> Void) {
            self.handler = handler
        }

        func call(_ data: Data) {
            handler(data)
        }
    }

    init(coordinator: WatchConnectivityCoordinator) {
        self.coordinator = coordinator
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [coordinator] in coordinator.didCompleteActivation() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // The Watch client consumes context through its own freshness/handshake rules.
        // The phone never treats context as a command channel.
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let reply = ReplyHandlerBox(replyHandler)
        Task { @MainActor [coordinator, reply] in
            if (try? WatchCodec.decode(WatchSnapshotRequest.self, from: messageData)) != nil {
                coordinator.receiveSnapshotRequest(messageData, reply: reply.call)
            } else if (try? WatchCodec.decode(WatchMutatingCommandEnvelope.self, from: messageData)) != nil {
                coordinator.receiveCommand(messageData, reply: reply.call)
            } else {
                reply.call(Data())
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [coordinator] in coordinator.activateIfNeeded() }
    }
    #endif
}

#endif
