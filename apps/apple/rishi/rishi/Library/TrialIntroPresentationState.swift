import Foundation
import Observation

@MainActor
@Observable
final class TrialIntroPresentationState {
    enum Source: Hashable { case signedIn, signedInContent, library, libraryRoot, purchaseError }
    struct Registration: Hashable { let id: UUID; let identity: LibraryAccountIdentity?; let source: Source }
    private struct Entry {
        let registration: Registration
        let provider: @MainActor () -> TrialChildSafety?
    }
    private struct ErrorEntry {
        let id: UUID
        let sourceID: ObjectIdentifier
        var provider: @MainActor () -> Bool
    }

    let hostID: UUID
    private var rootProvider: (@MainActor () -> TrialIntroPresentationSnapshot)?
    private var entries: [UUID: Entry] = [:]
    private var errorEntries: [UUID: ErrorEntry] = [:]
    private var deferredErrorRetirements: Set<UUID> = []
    private(set) var revision: UInt64 = 0
    private(set) var pendingReadyIdentity: LibraryAccountIdentity?
    private(set) var recoveryActiveIdentity: LibraryAccountIdentity?
    private var deferredRetirements: Set<UUID> = []
    private var cachedFacts: TrialIntroPresentationSnapshot?
    @ObservationIgnored private var hostLifetimeToken: TrialRootLifetimeAuthority.Anchor?
    @ObservationIgnored private var hostLifetimeIsCurrent: (@MainActor (TrialRootLifetimeAuthority.Anchor) -> Bool)?
    @ObservationIgnored private var hostRetirementObservers: [UUID: (TrialRootLifetimeAuthority.Anchor, @MainActor () -> Void)] = [:]

    init(hostID: UUID = UUID()) { self.hostID = hostID }

    func registerRoot(_ provider: @escaping @MainActor () -> TrialIntroPresentationSnapshot) { rootProvider = provider; advance() }
    func unregisterRoot() { rootProvider = nil; entries.removeAll(); pendingReadyIdentity = nil; retireCurrentHostLifetime(); advance() }

    func installHostLifetime(
        _ token: TrialRootLifetimeAuthority.Anchor,
        isCurrent: @escaping @MainActor (TrialRootLifetimeAuthority.Anchor) -> Bool
    ) {
        if hostLifetimeToken != token { retireCurrentHostLifetime() }
        hostLifetimeToken = token
        hostLifetimeIsCurrent = isCurrent
    }

    var currentHostLifetimeToken: TrialRootLifetimeAuthority.Anchor? { hostLifetimeToken }

    func isHostLifetimeCurrent(_ token: TrialRootLifetimeAuthority.Anchor, identity: LibraryAccountIdentity) -> Bool {
        guard hostLifetimeToken == token, hostLifetimeIsCurrent?(token) == true,
              let root = rootProvider?(), root.identity == identity else { return false }
        return root.hostActive
    }

    @discardableResult
    func observeHostRetirement(
        _ token: TrialRootLifetimeAuthority.Anchor,
        revoke: @escaping @MainActor () -> Void
    ) -> UUID? {
        guard hostLifetimeToken == token, hostLifetimeIsCurrent?(token) == true else { return nil }
        let id = UUID()
        hostRetirementObservers[id] = (token, revoke)
        return id
    }

    func removeHostRetirementObserver(_ id: UUID) { hostRetirementObservers.removeValue(forKey: id) }

    func retireHostLifetime(_ token: TrialRootLifetimeAuthority.Anchor) {
        guard hostLifetimeToken == token else { return }
        retireCurrentHostLifetime()
    }

    private func retireCurrentHostLifetime() {
        guard let token = hostLifetimeToken else { return }
        hostLifetimeToken = nil
        hostLifetimeIsCurrent = nil
        let callbacks = hostRetirementObservers.filter { $0.value.0 == token }.map(\.value.1)
        hostRetirementObservers = hostRetirementObservers.filter { $0.value.0 != token }
        callbacks.forEach { $0() }
    }

    @discardableResult
    func register(_ source: Source, identity: LibraryAccountIdentity?, provider: @escaping @MainActor () -> TrialChildSafety?) -> Registration {
        let registration = Registration(id: UUID(), identity: identity, source: source)
        entries[registration.id] = Entry(registration: registration, provider: provider)
        advance()
        return registration
    }

    func unregister(_ registration: Registration, deferredUnderCover claimID: UUID? = nil) {
        guard entries[registration.id]?.registration == registration else { return }
        if let claimID, isOwnedCover(claimID) { deferredRetirements.insert(registration.id); return }
        entries.removeValue(forKey: registration.id)
        advance()
    }

    func registerPurchaseError(source: AnyObject, provider: @escaping @MainActor () -> Bool) -> UUID {
        let sourceID = ObjectIdentifier(source)
        if let entryID = errorEntries.first(where: { $0.value.sourceID == sourceID })?.key {
            errorEntries[entryID]?.provider = provider
            deferredErrorRetirements.remove(entryID)
            _ = snapshot()
            return entryID
        }
        let id = UUID()
        errorEntries[id] = ErrorEntry(id: id, sourceID: sourceID, provider: provider)
        _ = snapshot()
        return id
    }
    func unregisterPurchaseError(source: AnyObject, deferredUnderCover claimID: UUID? = nil) {
        let sourceID = ObjectIdentifier(source)
        guard let id = errorEntries.first(where: { $0.value.sourceID == sourceID })?.key else { return }
        if let claimID, isOwnedCover(claimID) { deferredErrorRetirements.insert(id); return }
        errorEntries.removeValue(forKey: id)
        _ = snapshot()
    }

    func update() { _ = snapshot() }
    func requestLibraryReady(identity: LibraryAccountIdentity) {
        guard currentIdentity == identity else { return }
        guard pendingReadyIdentity != identity else { return }
        pendingReadyIdentity = identity
        advance()
    }
    func setRecoveryActive(_ active: Bool, identity: LibraryAccountIdentity) {
        guard currentIdentity == identity else { return }
        let wasActive = recoveryActiveIdentity == identity
        guard wasActive != active else { return }
        recoveryActiveIdentity = active ? identity : (recoveryActiveIdentity == identity ? nil : recoveryActiveIdentity)
        advance()
    }
    func consumeReady(identity: LibraryAccountIdentity) { if pendingReadyIdentity == identity { pendingReadyIdentity = nil; advance() } }
    func invalidate(identity: LibraryAccountIdentity) {
        if pendingReadyIdentity == identity { pendingReadyIdentity = nil }
        if recoveryActiveIdentity == identity { recoveryActiveIdentity = nil }
        entries = entries.filter { $0.value.registration.identity != identity }
        if rootProvider?().identity == identity { retireCurrentHostLifetime() }
        advance()
    }

    var currentIdentity: LibraryAccountIdentity? { rootProvider?().identity }
    var activeOwnedCoverClaimID: UUID? { activeClaimID }
    var hasPendingReady: Bool { pendingReadyIdentity != nil }
    var currentRevision: UInt64 { revision }

    func snapshot() -> TrialIntroPresentationSnapshot? {
        guard var root = rootProvider?() else { return nil }
        let identity = root.identity
        let required: Set<Source> = [.signedIn, .signedInContent, .library, .libraryRoot]
        let current = entries.values.filter { entry in
            entry.registration.source != .purchaseError && entry.registration.identity == identity
        }
        if let identity,
           required.isSubset(of: Set(current.map { $0.registration.source })) {
            let reports = current.compactMap { $0.provider() }
            if reports.count == current.count, !reports.isEmpty {
                var merged = TrialChildSafety()
                merged.signedIn = reports.allSatisfy(\.signedIn)
                merged.consent = reports.allSatisfy(\.consent)
                merged.conversation = reports.allSatisfy(\.conversation)
                merged.voice = reports.allSatisfy(\.voice)
                merged.libraryReady = reports.allSatisfy(\.libraryReady)
                merged.libraryModal = reports.allSatisfy(\.libraryModal)
                merged.firstBookFlowActive = reports.contains(where: \.firstBookFlowActive)
                    || recoveryActiveIdentity == identity
                root.child = merged
            } else {
                root.child = nil
            }
        } else {
            root.child = nil
        }
        root.nativePresentationActive = root.nativePresentationActive || errorEntries.isEmpty
            || errorEntries.values.contains(where: { $0.provider() })
        var facts = root
        facts.revision = 0
        if cachedFacts != facts {
            revision &+= 1
            cachedFacts = facts
        }
        root.revision = revision
        return root
    }

    func coverDidDismiss(claimID: UUID) {
        guard isOwnedCover(claimID) else { return }
        deferredRetirements.forEach { entries.removeValue(forKey: $0) }
        deferredRetirements.removeAll()
        deferredErrorRetirements.forEach { errorEntries.removeValue(forKey: $0) }
        deferredErrorRetirements.removeAll()
        advance()
    }

    private var activeClaimID: UUID?
    func setOwnedCover(_ claimID: UUID?) {
        guard activeClaimID != claimID else { return }
        activeClaimID = claimID
        advance()
    }
    private func isOwnedCover(_ id: UUID) -> Bool { activeClaimID == id }
    private func advance() { revision &+= 1 }
}

@MainActor
@Observable
final class TrialLegacySampleOperationTracker {
    private(set) var identity: LibraryAccountIdentity?
    private(set) var operationIDs: Set<UUID> = []

    func begin(identity: LibraryAccountIdentity) -> UUID {
        if self.identity != identity { operationIDs.removeAll(); self.identity = identity }
        let token = UUID()
        operationIDs.insert(token)
        return token
    }

    @discardableResult
    func finish(_ token: UUID, identity expected: LibraryAccountIdentity, currentIdentity: LibraryAccountIdentity?) -> Bool {
        guard identity == expected, currentIdentity == expected, operationIDs.contains(token) else { return false }
        operationIDs.remove(token)
        return true
    }

    func isActive(for identity: LibraryAccountIdentity) -> Bool {
        self.identity == identity && !operationIDs.isEmpty
    }
}

@MainActor
final class TrialRootLifetimeAuthority {
    struct Anchor: Equatable {
        let registrationID: UUID
        let hostID: UUID
        let graphID: UUID
        let sceneID: UUID
    }

    struct Status: Equatable {
        let graphAlive: Bool
        let sceneConnected: Bool
        let sceneActive: Bool
    }
    struct SnapshotFacts: Equatable {
        let hostActive: Bool
        let sceneActive: Bool
    }

    private(set) var currentAnchor: Anchor?
    private(set) var currentStatus: Status?
    private var deferredRetirementID: UUID?
    private var latestRetiredAnchor: Anchor?

    func register(hostID: UUID, graphID: UUID, sceneID: UUID, sceneActive: Bool = false) -> Anchor {
        let anchor = Anchor(registrationID: UUID(), hostID: hostID, graphID: graphID, sceneID: sceneID)
        currentAnchor = anchor
        currentStatus = Status(graphAlive: true, sceneConnected: true, sceneActive: sceneActive)
        deferredRetirementID = nil
        latestRetiredAnchor = nil
        return anchor
    }

    func isCurrent(_ anchor: Anchor) -> Bool { currentAnchor == anchor }
    func isLatestRetired(_ anchor: Anchor) -> Bool { currentAnchor == nil && latestRetiredAnchor == anchor }

    func status(hostID: UUID, graphID: UUID) -> Status? {
        guard let anchor = currentAnchor, anchor.hostID == hostID, anchor.graphID == graphID else { return nil }
        return currentStatus
    }

    func retainAfterTransientWindowDetach(_ anchor: Anchor) -> Bool {
        currentAnchor == anchor && currentStatus?.sceneConnected == true
    }

    func snapshotFacts(hostID: UUID, graphID: UUID, localSceneIsActive: Bool) -> SnapshotFacts {
        guard let status = status(hostID: hostID, graphID: graphID) else {
            return SnapshotFacts(hostActive: false, sceneActive: false)
        }
        return SnapshotFacts(
            hostActive: status.graphAlive && status.sceneConnected,
            sceneActive: status.sceneActive && localSceneIsActive
        )
    }

    @discardableResult
    func setSceneActive(_ anchor: Anchor, active: Bool) -> Bool {
        guard currentAnchor == anchor, let status = currentStatus, status.sceneConnected else { return false }
        currentStatus = Status(graphAlive: true, sceneConnected: true, sceneActive: active)
        return true
    }

    func retire(_ anchor: Anchor) -> Bool {
        guard currentAnchor == anchor else { return false }
        currentAnchor = nil
        currentStatus = nil
        deferredRetirementID = nil
        latestRetiredAnchor = anchor
        return true
    }

    func sceneDidDisconnect(anchor: Anchor, sceneID: UUID) -> Bool {
        guard anchor.sceneID == sceneID, currentAnchor == anchor else { return false }
        return retire(anchor)
    }

    func deferRetirement(_ anchor: Anchor) -> Bool {
        guard currentAnchor == anchor else { return false }
        deferredRetirementID = anchor.registrationID
        return true
    }

    func ownedCoverDidDismiss(hostID: UUID) -> Bool {
        guard let anchor = currentAnchor, anchor.hostID == hostID,
              deferredRetirementID == anchor.registrationID else { return false }
        return retire(anchor)
    }
}
