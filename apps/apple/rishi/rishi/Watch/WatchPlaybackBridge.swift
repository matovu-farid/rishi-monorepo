#if os(iOS) && canImport(WatchConnectivity)

import Foundation
import ReadiumShared
import RishiWatchShared

@MainActor
final class WatchPlaybackBridge: WatchConnectivityCommandHandling {
    private static let markerKey = "rishi.watch.redaction.marker"
    private static let revisionKey = "rishi.watch.redaction.revision"
    private static let activationFloorsKey = "rishi.watch.activation.floors"

    private let owner: ReadAloudPlaybackOwner
    private let processSessionID: UUID
    private var redactionRevision: UInt64 = 0
    private var marker: WatchRedactionMarker?
    private var accountInvalidated = false
    private var serverSequence: UInt64 = 0
    private var currentHandshake: (UUID, UInt64)?
    private var lastSnapshotRequest: WatchSnapshotRequest?
    private let receiptLedger = WatchReceiptLedger()
    private let remoteCommandQueue: RemoteCommandQueue
    private let redactionDefaults: UserDefaults?
    private var minimumActivationSequences: [String: UInt64]

    init(owner: ReadAloudPlaybackOwner) {
        self.owner = owner
        let processSessionID = UUID()
        self.processSessionID = processSessionID
        self.remoteCommandQueue = RemoteCommandQueue(processSessionID: processSessionID)
        let defaults = UserDefaults(suiteName: "group.org.fidexa.rishi")
        self.redactionDefaults = defaults
        if let data = defaults?.data(forKey: Self.activationFloorsKey),
           let floors = try? WatchCodec.decode([String: UInt64].self, from: data) {
            self.minimumActivationSequences = floors
        } else {
            self.minimumActivationSequences = [:]
        }
        if let data = defaults?.data(forKey: Self.revisionKey),
           let revision = try? WatchCodec.decode(UInt64.self, from: data) {
            self.redactionRevision = revision
        } else if let data = defaults?.data(forKey: Self.markerKey),
                  let previousMarker = try? WatchCodec.decode(WatchRedactionMarker.self, from: data) {
            self.redactionRevision = previousMarker.redactionRevision
        }
    }

    func invalidateForAccountChange() {
        guard !accountInvalidated else { return }
        accountInvalidated = true
        marker = nil
        currentHandshake = nil
        remoteCommandQueue.revokeAll()
        Task { await receiptLedger.invalidateReceipts() }
        for key in Array(minimumActivationSequences.keys) {
            minimumActivationSequences[key] = (minimumActivationSequences[key] ?? 0) &+ 1
        }
        if let request = lastSnapshotRequest {
            let key = request.watchClientID.uuidString
            minimumActivationSequences[key] = max(
                minimumActivationSequences[key] ?? 0,
                request.activationSequence &+ 1
            )
        }
        redactionRevision &+= 1
        _ = persistRedactionRevision()
        persistActivationFloors()
        redactionDefaults?.removeObject(forKey: Self.markerKey)
    }

    func redactedSnapshotForCurrentClient() -> WatchPlaybackSnapshot? {
        guard let request = lastSnapshotRequest else { return nil }
        return unavailableSnapshot(request: request, reason: .accountUnavailable)
    }

    func installVerifiedMarker(minimumAccountGeneration: UInt64) throws {
        redactionRevision &+= 1
        let next = WatchRedactionMarker(
            processSessionID: processSessionID,
            redactionRevision: redactionRevision,
            minimumAccountGeneration: minimumAccountGeneration
        )
        guard persistRedactionRevision() else {
            marker = nil
            redactionDefaults?.removeObject(forKey: Self.markerKey)
            throw WatchCodecError.invalidPayload
        }
        let data = try WatchCodec.encode(next)
        redactionDefaults?.set(data, forKey: Self.markerKey)
        guard redactionDefaults?.data(forKey: Self.markerKey) == data else {
            marker = nil
            redactionDefaults?.removeObject(forKey: Self.markerKey)
            throw WatchCodecError.invalidPayload
        }
        marker = next
        accountInvalidated = false
        currentHandshake = nil
        remoteCommandQueue.installAccountGeneration(minimumAccountGeneration)
    }

    func watchSnapshot(request: WatchSnapshotRequest) -> WatchPlaybackSnapshot {
        let clientKey = request.watchClientID.uuidString
        if request.activationSequence < (minimumActivationSequences[clientKey] ?? 0) {
            return unavailableSnapshot(request: request, reason: .staleProcess)
        }
        minimumActivationSequences[clientKey] = max(
            minimumActivationSequences[clientKey] ?? 0,
            request.activationSequence
        )
        persistActivationFloors()
        guard remoteCommandQueue.installHandshake(
            clientID: request.watchClientID,
            nonce: request.handshakeNonce,
            activationSequence: request.activationSequence
        ) else {
            return unavailableSnapshot(request: request, reason: .staleProcess)
        }
        lastSnapshotRequest = request
        currentHandshake = (request.handshakeNonce, request.activationSequence)
        serverSequence &+= 1
        let controller = owner.activeController
        let hasActivePlayback = owner.hasActivePlaybackSession
        let isVerified = marker != nil
        if isVerified, hasActivePlayback {
            remoteCommandQueue.installPlaybackSession(
                accountGeneration: marker!.minimumAccountGeneration,
                playbackGeneration: owner.generation
            )
        } else {
            remoteCommandQueue.revokePlaybackSession()
        }
        let locatorProgress = controller?.currentLocator?.locations.progression
        let totalProgress = controller?.currentLocator?.locations.totalProgression
        let displayProgress = totalProgress ?? locatorProgress
        return WatchPlaybackSnapshot(
            processSessionID: processSessionID,
            handshakeNonce: request.handshakeNonce,
            activationSequence: request.activationSequence,
            serverSequence: serverSequence,
            redactionRevision: marker?.redactionRevision ?? redactionRevision,
            redactionTrust: isVerified ? .verified : .unverified,
            playbackGeneration: owner.generation,
            accountGeneration: marker?.minimumAccountGeneration ?? 0,
            availability: hasActivePlayback ? .active : .unavailable,
            title: isVerified && hasActivePlayback ? owner.watchBookTitle : nil,
            chapterTitle: isVerified && hasActivePlayback ? controller?.currentLocator?.title : nil,
            progress: isVerified && hasActivePlayback ? displayProgress : nil,
            isPlaying: isVerified && hasActivePlayback && (controller?.isActivelySpeaking ?? false),
            playbackRate: isVerified && hasActivePlayback ? controller?.pickerInitial.speed : nil,
            supportedPlaybackRates: isVerified && hasActivePlayback ? Array(TTSSettings.speedPresets) : [],
            currentNarrationUnit: isVerified && hasActivePlayback ? controller?.currentParagraph : nil,
            progressScope: isVerified && hasActivePlayback && displayProgress != nil
                ? (totalProgress != nil ? .book : .resource)
                : nil,
            validUntil: Date().addingTimeInterval(45)
        )
    }

    private func persistActivationFloors() {
        guard let data = try? WatchCodec.encode(minimumActivationSequences) else { return }
        redactionDefaults?.set(data, forKey: Self.activationFloorsKey)
    }

    private func persistRedactionRevision() -> Bool {
        guard let data = try? WatchCodec.encode(redactionRevision) else { return false }
        redactionDefaults?.set(data, forKey: Self.revisionKey)
        return redactionDefaults?.data(forKey: Self.revisionKey) == data
    }

    private func matchesCurrentHandshake(_ request: WatchSnapshotRequest) -> Bool {
        currentHandshake?.0 == request.handshakeNonce
            && currentHandshake?.1 == request.activationSequence
    }

    func handleWatchCommand(_ envelope: WatchMutatingCommandEnvelope) async -> WatchAcknowledgement {
        guard let marker else {
            return acknowledgement(for: envelope, accepted: false, reason: .accountUnavailable)
        }
        guard marker.processSessionID == processSessionID,
              let lease = remoteCommandQueue.admit(envelope) else {
            return acknowledgement(for: envelope, accepted: false, reason: .staleProcess)
        }

        // The ledger validates duplicate payload digests before replaying a
        // receipt. Keep this behind live-epoch admission so an old receipt
        // cannot republish metadata after process/account fencing.
        let admission: WatchReceiptAdmission
        do {
            admission = try await receiptLedger.admit(envelope)
        } catch WatchCodecError.staleSequence {
            lease.finish()
            return acknowledgement(for: envelope, accepted: false, reason: .staleGeneration)
        } catch WatchCodecError.staleCommand {
            lease.finish()
            return acknowledgement(for: envelope, accepted: false, reason: .executionTimedOut)
        } catch WatchCodecError.capacityExceeded {
            lease.finish()
            return acknowledgement(for: envelope, accepted: false, reason: .busy)
        } catch WatchCodecError.invalidPayload {
            lease.finish()
            return acknowledgement(for: envelope, accepted: false, reason: .invalidCommand)
        } catch {
            lease.finish()
            return acknowledgement(for: envelope, accepted: false, reason: .executionFailed)
        }
        switch admission {
        case let .terminal(receipt):
            lease.finish()
            if case let .terminal(acknowledgement) = receipt.status {
                return acknowledgement
            }
            return deferredAcknowledgement(for: envelope, reason: .busy)
        case .inFlight:
            lease.finish()
            return deferredAcknowledgement(for: envelope, reason: .busy)
        case .new:
            break
        }
        let result: WatchAcknowledgement
        do {
            try await owner.executeRemoteWatchCommand(
                envelope.command,
                expectedGeneration: envelope.playbackGeneration,
                lease: lease
            )
            result = acknowledgement(for: envelope, accepted: true)
        } catch RemotePlaybackCommandError.noActivePlayback {
            result = acknowledgement(for: envelope, accepted: false, reason: .noActivePlayback)
        } catch RemotePlaybackCommandError.staleGeneration {
            result = acknowledgement(for: envelope, accepted: false, reason: .staleGeneration)
        } catch RemotePlaybackCommandError.invalidCommand {
            result = acknowledgement(for: envelope, accepted: false, reason: .invalidCommand)
        } catch RemotePlaybackCommandError.revoked {
            result = acknowledgement(for: envelope, accepted: false, reason: .fenced)
        } catch {
            result = acknowledgement(for: envelope, accepted: false, reason: .executionFailed)
        }
        await receiptLedger.settle(requestID: envelope.requestID, acknowledgement: result)
        return result
    }

    private func acknowledgement(for envelope: WatchMutatingCommandEnvelope, accepted: Bool, reason: WatchRejectionReason? = nil) -> WatchAcknowledgement {
        let request = WatchSnapshotRequest(
            watchClientID: envelope.watchClientID,
            handshakeNonce: envelope.handshakeNonce,
            activationSequence: envelope.activationSequence
        )
        let snapshot = matchesCurrentHandshake(request)
            ? watchSnapshot(request: request)
            : unavailableSnapshot(request: request, reason: reason ?? .staleProcess)
        return WatchAcknowledgement(
            requestID: envelope.requestID,
            disposition: .terminal,
            accepted: accepted,
            rejectionReason: reason,
            serverSequence: serverSequence,
            snapshot: snapshot
        )
    }

    private func deferredAcknowledgement(for envelope: WatchMutatingCommandEnvelope, reason: WatchRejectionReason) -> WatchAcknowledgement {
        let request = WatchSnapshotRequest(
            watchClientID: envelope.watchClientID,
            handshakeNonce: envelope.handshakeNonce,
            activationSequence: envelope.activationSequence
        )
        return WatchAcknowledgement(
            requestID: envelope.requestID,
            disposition: .deferred,
            accepted: false,
            rejectionReason: reason,
            serverSequence: serverSequence,
            snapshot: matchesCurrentHandshake(request)
                ? watchSnapshot(request: request)
                : unavailableSnapshot(request: request, reason: .staleProcess)
        )
    }

    private func unavailableSnapshot(request: WatchSnapshotRequest, reason: WatchRejectionReason) -> WatchPlaybackSnapshot {
        WatchPlaybackSnapshot(
            processSessionID: processSessionID,
            handshakeNonce: request.handshakeNonce,
            activationSequence: request.activationSequence,
            serverSequence: serverSequence,
            redactionRevision: marker?.redactionRevision ?? redactionRevision,
            redactionTrust: .unverified,
            playbackGeneration: owner.generation,
            accountGeneration: marker?.minimumAccountGeneration ?? 0,
            availability: .unknown(rawValue: reason.rawValue),
            validUntil: Date().addingTimeInterval(15)
        )
    }
}

#endif
