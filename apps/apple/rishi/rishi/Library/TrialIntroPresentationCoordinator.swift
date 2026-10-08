import Foundation
import Observation

@MainActor
@Observable
final class TrialIntroPresentationCoordinator {
    enum Outcome: Equatable {
        case alreadySeen, ineligible, presented(UUID), blockedByOtherClaim(UUID), factsChanged, presentationRefused, cancelled
    }
    enum Phase { case checking, awaitingAppearance, committing }
    struct Claim {
        let id: UUID
        let hostID: UUID
        let identity: LibraryAccountIdentity
        var phase: Phase
        var expectedRevision: UInt64
    }
    struct Effects {
        var hasSeen: @MainActor (UUID) async -> Bool
        var refreshEntitlement: @MainActor () async -> Result<EntitlementSnapshot, Error>?
        var setSeenTrue: @MainActor (UUID) async -> Void
    }
    struct Host {
        var snapshot: @MainActor () -> TrialIntroPresentationSnapshot?
        var bindCover: @MainActor (UUID) -> Bool
        var dismissCover: @MainActor (UUID) -> Void
    }

    private(set) var availabilityRevision: UInt64 = 0
    private var claims: [UUID: Claim] = [:]
    private var outcomes: [UUID: Outcome] = [:]
    private var releaseSequence: UInt64 = 0
    private var releasedClaims: [UUID: (accountID: UUID, sequence: UInt64)] = [:]
    private var releaseObservers: [UUID: @MainActor (UUID, UUID, UInt64) -> Void] = [:]

    func observeReleases(_ observer: @escaping @MainActor (UUID, UUID, UInt64) -> Void) -> UUID {
        let id = UUID(); releaseObservers[id] = observer; return id
    }
    func removeReleaseObserver(_ id: UUID) { releaseObservers.removeValue(forKey: id) }
    func claim(for accountID: UUID) -> Claim? { claims[accountID] }
    func outcome(for hostID: UUID) -> Outcome? { outcomes[hostID] }
    func wasReleased(claimID: UUID, accountID: UUID) -> Bool {
        releasedClaims[claimID]?.accountID == accountID
    }

    func evaluate(hostID: UUID, state: TrialIntroPresentationState, identity: LibraryAccountIdentity,
                  effects: Effects, host: Host) async -> Outcome {
        guard !Task.isCancelled else { return record(.cancelled, for: hostID) }
        guard let snapshot = host.snapshot(), snapshot.hostID == hostID,
              snapshot.identity == identity, snapshot.permitsCheck,
              state.pendingReadyIdentity == identity else { return record(.factsChanged, for: hostID) }
        if let existing = claims[identity.userID] {
            return record(.blockedByOtherClaim(existing.id), for: hostID)
        }
        var claim = Claim(id: UUID(), hostID: hostID, identity: identity, phase: .checking, expectedRevision: snapshot.revision)
        claims[identity.userID] = claim
        availabilityRevision &+= 1

        guard valid(claim, hostID: hostID, host: host, state: state) else { return reject(claim, hostID: hostID) }
        let alreadySeen = await effects.hasSeen(identity.userID)
        guard valid(claim, hostID: hostID, host: host, state: state) else { return reject(claim, hostID: hostID) }
        if alreadySeen { state.consumeReady(identity: identity); release(claim); return record(.alreadySeen, for: hostID) }

        let refresh = await effects.refreshEntitlement()
        guard valid(claim, hostID: hostID, host: host, state: state) else { return reject(claim, hostID: hostID) }
        guard NoCardTrialIntroEligibility.shouldPresent(for: refresh) else {
            state.consumeReady(identity: identity); release(claim); return record(.ineligible, for: hostID)
        }
        let seenAgain = await effects.hasSeen(identity.userID)
        guard valid(claim, hostID: hostID, host: host, state: state) else { return reject(claim, hostID: hostID) }
        if seenAgain { state.consumeReady(identity: identity); release(claim); return record(.alreadySeen, for: hostID) }

        guard let beforeBind = host.snapshot(), beforeBind.identity == identity,
              beforeBind.revision == claim.expectedRevision, beforeBind.permitsCheck,
              host.bindCover(claim.id), var current = claims[identity.userID], current.id == claim.id else {
            release(claim); return record(.presentationRefused, for: hostID)
        }
        current.phase = .awaitingAppearance
        current.expectedRevision = host.snapshot()?.revision ?? .max
        claims[identity.userID] = current
        guard let bound = host.snapshot(), bound.permitsAppearance(claimID: claim.id, identity: identity, revision: current.expectedRevision) else {
            host.dismissCover(claim.id); release(current); return record(.presentationRefused, for: hostID)
        }
        outcomes[hostID] = .presented(claim.id)
        return .presented(claim.id)
    }

    func coverAppeared(claimID: UUID, hostID: UUID, state: TrialIntroPresentationState, host: Host, effects: Effects) async -> Bool {
        guard let claim = claims.values.first(where: { $0.id == claimID }), claim.hostID == hostID else {
            host.dismissCover(claimID)
            return false
        }
        guard claim.phase == .awaitingAppearance else {
            // A repeated onAppear after admission must not dismiss the cover or issue a second write.
            return false
        }
        guard !Task.isCancelled,
              let snapshot = host.snapshot(), snapshot.permitsAppearance(claimID: claimID, identity: claim.identity, revision: claim.expectedRevision),
              var current = claims[claim.identity.userID], current.id == claimID else {
            host.dismissCover(claimID)
            if let claim = claims.values.first(where: { $0.id == claimID }) { release(claim) }
            return false
        }
        current.phase = .committing
        claims[current.identity.userID] = current
        state.consumeReady(identity: current.identity)
        await effects.setSeenTrue(current.identity.userID)
        // A committed write is serialized through completion even if its host retires meanwhile.
        release(current)
        return !Task.isCancelled && host.snapshot()?.identity == current.identity
    }

    func retireHost(_ hostID: UUID) {
        let retiring = claims.values.filter { $0.hostID == hostID && $0.phase != .committing }
        for claim in retiring { release(claim) }
    }

    private func valid(_ claim: Claim, hostID: UUID, host: Host, state: TrialIntroPresentationState) -> Bool {
        guard !Task.isCancelled, claims[claim.identity.userID]?.id == claim.id,
              claim.hostID == hostID, let snapshot = host.snapshot(),
              snapshot.hostID == hostID, snapshot.identity == claim.identity,
              snapshot.revision == claim.expectedRevision, snapshot.permitsCheck,
              state.pendingReadyIdentity == claim.identity else { return false }
        return true
    }
    private func record(_ outcome: Outcome, for host: UUID) -> Outcome { outcomes[host] = outcome; return outcome }
    private func reject(_ claim: Claim, hostID: UUID) -> Outcome {
        release(claim)
        return record(Task.isCancelled ? .cancelled : .factsChanged, for: hostID)
    }
    private func release(_ claim: Claim) {
        guard claims[claim.identity.userID]?.id == claim.id else { return }
        claims.removeValue(forKey: claim.identity.userID)
        releaseSequence &+= 1
        releasedClaims[claim.id] = (claim.identity.userID, releaseSequence)
        availabilityRevision &+= 1
        for observer in releaseObservers.values { observer(claim.identity.userID, claim.id, releaseSequence) }
    }
}
