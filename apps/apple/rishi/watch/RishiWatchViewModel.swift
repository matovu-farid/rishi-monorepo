#if os(watchOS)

import Foundation
import Observation
import RishiWatchShared

@MainActor
@Observable
final class RishiWatchViewModel {
    private let client: RishiWatchConnectivityClient
    private(set) var snapshot: WatchPlaybackSnapshot?
    private(set) var pendingRequest: WatchMutatingCommandEnvelope?
    private(set) var isRetryable = false
    private(set) var errorMessage: String?
    private var retryTask: Task<Void, Never>?
    private var retryIndex = 0

    init(client: RishiWatchConnectivityClient) {
        self.client = client
    }

    func start() {
        clearForActivation()
        client.start(
            snapshotHandler: { [weak self] snapshot in self?.apply(snapshot) },
            acknowledgementHandler: { [weak self] acknowledgement in self?.apply(acknowledgement) },
            activationHandler: { [weak self] in self?.clearForActivation() },
            transportFailureHandler: { [weak self] requestID in self?.transportFailed(requestID: requestID) }
        )
    }

    func refresh() {
        guard pendingRequest == nil else { return }
        clearForActivation()
        client.requestSnapshot()
    }

    func send(_ command: WatchPlaybackCommand) {
        guard let snapshot, pendingRequest == nil, snapshot.redactionTrust == .verified else { return }
        let envelope = WatchMutatingCommandEnvelope(
            processSessionID: snapshot.processSessionID,
            watchClientID: client.clientID,
            handshakeNonce: snapshot.handshakeNonce,
            activationSequence: snapshot.activationSequence,
            clientSequence: client.nextClientSequence(),
            requestID: UUID(),
            playbackGeneration: snapshot.playbackGeneration,
            accountGeneration: snapshot.accountGeneration,
            command: command
        )
        retryTask?.cancel()
        retryIndex = 0
        isRetryable = false
        errorMessage = nil
        pendingRequest = envelope
        client.send(envelope)
        scheduleRetry(for: envelope)
    }

    func tick(now: Date = Date()) {
        if let snapshot, snapshot.validUntil <= now {
            self.snapshot = nil
            retryTask?.cancel()
            retryTask = nil
            if pendingRequest == nil {
                isRetryable = false
                retryIndex = 0
            } else {
                isRetryable = true
            }
        }
    }

    func retryPendingRequest() {
        guard let pendingRequest, isRetryable else { return }
        isRetryable = false
        errorMessage = nil
        retryTask?.cancel()
        retryTask = nil
        client.send(pendingRequest)
        scheduleRetry(for: pendingRequest)
    }

    private func clearForActivation() {
        snapshot = nil
        abandonPendingRequest()
        isRetryable = false
        errorMessage = nil
        retryTask?.cancel()
        retryTask = nil
        retryIndex = 0
    }

    private func abandonPendingRequest() {
        if let pendingRequest {
            client.abandon(requestID: pendingRequest.requestID)
        }
        pendingRequest = nil
    }

    private func transportFailed(requestID: UUID) {
        guard pendingRequest?.requestID == requestID else { return }
        retryTask?.cancel()
        retryTask = nil
        isRetryable = true
        errorMessage = "iPhone unreachable. Retry when Rishi is open."
    }

    private func apply(_ snapshot: WatchPlaybackSnapshot) {
        guard snapshot.redactionTrust == .verified else {
            self.snapshot = nil
            retryTask?.cancel()
            retryTask = nil
            abandonPendingRequest()
            isRetryable = false
            retryIndex = 0
            return
        }
        guard snapshot.validUntil > Date() else {
            self.snapshot = nil
            retryTask?.cancel()
            retryTask = nil
            if pendingRequest == nil {
                isRetryable = false
                retryIndex = 0
            } else {
                isRetryable = true
            }
            return
        }
        if let existing = self.snapshot {
            if snapshot.processSessionID != existing.processSessionID {
                retryTask?.cancel()
                retryTask = nil
                abandonPendingRequest()
                isRetryable = false
                retryIndex = 0
                errorMessage = nil
            } else if snapshot.handshakeNonce != existing.handshakeNonce
                        || snapshot.activationSequence != existing.activationSequence
                        || snapshot.accountGeneration != existing.accountGeneration
                        || snapshot.playbackGeneration != existing.playbackGeneration {
                retryTask?.cancel()
                retryTask = nil
                abandonPendingRequest()
                isRetryable = false
                retryIndex = 0
                errorMessage = nil
            } else if snapshot.serverSequence < existing.serverSequence {
                return
            }
        }
        self.snapshot = snapshot
    }

    private func apply(_ acknowledgement: WatchAcknowledgement) {
        guard let request = self.pendingRequest,
              acknowledgement.requestID == request.requestID,
              acknowledgement.snapshot.handshakeNonce == request.handshakeNonce,
              acknowledgement.snapshot.activationSequence == request.activationSequence else {
            return
        }
        if let existing = snapshot,
           existing.processSessionID == acknowledgement.snapshot.processSessionID,
           (existing.handshakeNonce != acknowledgement.snapshot.handshakeNonce
            || existing.activationSequence != acknowledgement.snapshot.activationSequence) {
            return
        }
        if acknowledgement.disposition == .terminal {
            retryTask?.cancel()
            retryTask = nil
            self.pendingRequest = nil
            isRetryable = false
            retryIndex = 0
        }
        if !acknowledgement.accepted {
            errorMessage = acknowledgement.rejectionReason?.rawValue
        }
        apply(acknowledgement.snapshot)
        if acknowledgement.disposition == .deferred, let request = self.pendingRequest {
            scheduleRetry(for: request)
        }
    }

    private func scheduleRetry(for envelope: WatchMutatingCommandEnvelope) {
        guard retryTask == nil else { return }
        let delays: [UInt64] = [5, 10, 20]
        guard retryIndex < delays.count else {
            errorMessage = "The iPhone has not confirmed this command."
            return
        }
        let delay = delays[retryIndex]
        retryIndex += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled, self.pendingRequest?.requestID == envelope.requestID else { return }
            self.retryTask = nil
            self.client.send(envelope)
            self.scheduleRetry(for: envelope)
        }
    }
}

#endif
