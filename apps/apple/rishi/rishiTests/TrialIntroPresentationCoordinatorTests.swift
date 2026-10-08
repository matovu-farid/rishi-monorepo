@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Trial intro presentation coordinator")
struct TrialIntroPresentationCoordinatorTests {
    @Test("fresh eligibility precedes presentation and visible matching appearance writes seen once")
    func appearanceIsSeenWriteBoundary() async {
        let identity = accountIdentity()
        let host = TrialHostHarness(identity: identity)
        let effects = TrialEffectsHarness()
        let coordinator = TrialIntroPresentationCoordinator()

        let outcome = await coordinator.evaluate(
            hostID: host.state.hostID,
            state: host.state,
            identity: identity,
            effects: effects.effects,
            host: host.callbacks
        )

        guard case .presented(let claimID) = outcome else {
            Issue.record("Expected a presented claim, received \(outcome)")
            return
        }
        #expect(effects.events == ["seen-read", "refresh", "seen-reread"])
        #expect(effects.seenWrites.isEmpty)
        #expect(host.presentation == .claimedTrialIntro(claimID))

        #expect(await coordinator.coverAppeared(
            claimID: claimID, hostID: host.state.hostID, state: host.state,
            host: host.callbacks, effects: effects.effects
        ))
        #expect(effects.seenWrites == [identity.userID])
        #expect(await coordinator.coverAppeared(
            claimID: claimID, hostID: host.state.hostID, state: host.state,
            host: host.callbacks, effects: effects.effects
        ) == false)
        #expect(effects.seenWrites == [identity.userID])
    }

    @Test("a modal appearing before cover appearance dismisses without recording seen")
    func competingPresentationBeforeAppearanceDoesNotCommit() async {
        let identity = accountIdentity()
        let host = TrialHostHarness(identity: identity)
        let effects = TrialEffectsHarness()
        let coordinator = TrialIntroPresentationCoordinator()
        let result = await coordinator.evaluate(hostID: host.state.hostID, state: host.state,
                                                identity: identity, effects: effects.effects,
                                                host: host.callbacks)
        guard case .presented(let claimID) = result else {
            Issue.record("Expected a presentation claim")
            return
        }

        host.childModal = true
        host.state.update()
        let appeared = await coordinator.coverAppeared(
            claimID: claimID, hostID: host.state.hostID, state: host.state,
            host: host.callbacks, effects: effects.effects
        )

        #expect(!appeared)
        #expect(effects.seenWrites.isEmpty)
        #expect(host.dismissedClaims == [claimID])
        #expect(host.state.pendingReadyIdentity == identity)
        #expect(coordinator.claim(for: identity.userID) == nil)
    }

    @Test("a new root competitor takes precedence over the coordinator's own claimed cover")
    func newRootCompetitorRefusesOwnedCoverAppearance() async {
        let identity = accountIdentity()
        let host = TrialHostHarness(identity: identity)
        let effects = TrialEffectsHarness()
        let coordinator = TrialIntroPresentationCoordinator()
        let result = await coordinator.evaluate(hostID: host.state.hostID, state: host.state,
                                                identity: identity, effects: effects.effects,
                                                host: host.callbacks)
        guard case .presented(let claimID) = result else {
            Issue.record("Expected an owned cover claim")
            return
        }

        host.competingRootModal = true
        host.state.update()
        let snapshot = host.state.snapshot()
        #expect(snapshot?.rootPresentation == .other)
        #expect(await coordinator.coverAppeared(claimID: claimID, hostID: host.state.hostID,
                                                state: host.state, host: host.callbacks,
                                                effects: effects.effects) == false)
        #expect(host.dismissedClaims == [claimID])
        #expect(effects.seenWrites.isEmpty)
    }

    @Test("two hosts share one account claim while seen lookup is suspended")
    func processWideClaimSerializesHosts() async {
        let identity = accountIdentity()
        let first = TrialHostHarness(identity: identity)
        let second = TrialHostHarness(identity: identity)
        let coordinator = TrialIntroPresentationCoordinator()
        let gate = AsyncTestGate()
        let firstEffects = TrialEffectsHarness(seenGate: gate)
        let secondEffects = TrialEffectsHarness()

        let evaluation = Task { @MainActor in
            await coordinator.evaluate(hostID: first.state.hostID, state: first.state,
                                       identity: identity, effects: firstEffects.effects,
                                       host: first.callbacks)
        }
        #expect(await gate.waitUntilEntered())
        let competing = await coordinator.evaluate(hostID: second.state.hostID, state: second.state,
                                                   identity: identity, effects: secondEffects.effects,
                                                   host: second.callbacks)
        #expect(competing == .blockedByOtherClaim(coordinator.claim(for: identity.userID)!.id))
        #expect(secondEffects.events.isEmpty)

        await gate.open()
        let firstResult = await evaluation.value
        guard case .presented(let claimID) = firstResult else {
            Issue.record("Expected first host to present")
            return
        }
        #expect(coordinator.claim(for: identity.userID)?.id == claimID)
        #expect(secondEffects.events.isEmpty)
    }

    @Test("safe-state changes during every suspended pre-presentation await prevent presentation")
    func changedFactsAfterAwaitDenyAndRetainReadiness() async {
        let identity = accountIdentity()

        for suspension in ["seen-read", "refresh", "seen-reread"] {
            let host = TrialHostHarness(identity: identity)
            let gate = AsyncTestGate()
            let effects = TrialEffectsHarness(gateAt: suspension, gate: gate)
            let coordinator = TrialIntroPresentationCoordinator()
            let evaluation = Task { @MainActor in
                await coordinator.evaluate(hostID: host.state.hostID, state: host.state,
                                           identity: identity, effects: effects.effects,
                                           host: host.callbacks)
            }
            #expect(await gate.waitUntilEntered())
            host.sceneActive = false
            host.state.update()
            await gate.open()
            let result = await evaluation.value

            #expect(result == .factsChanged)
            #expect(host.bindCount == 0)
            #expect(effects.seenWrites.isEmpty)
            #expect(host.state.pendingReadyIdentity == identity)
        }
    }

    @Test("sample recovery activity blocks the retained request until the final exact token finishes")
    func legacySampleActivityDefersTrialCheck() async {
        let identity = accountIdentity()
        let tracker = TrialLegacySampleOperationTracker()
        let host = TrialHostHarness(identity: identity, legacyTracker: tracker)
        let first = tracker.begin(identity: identity)
        let second = tracker.begin(identity: identity)
        host.state.update()
        let effects = TrialEffectsHarness()
        let coordinator = TrialIntroPresentationCoordinator()

        #expect(await coordinator.evaluate(hostID: host.state.hostID, state: host.state,
                                            identity: identity, effects: effects.effects,
                                            host: host.callbacks) == .factsChanged)
        #expect(effects.events.isEmpty)

        #expect(tracker.finish(first, identity: identity, currentIdentity: identity))
        host.state.update()
        #expect(await coordinator.evaluate(hostID: host.state.hostID, state: host.state,
                                            identity: identity, effects: effects.effects,
                                            host: host.callbacks) == .factsChanged)
        #expect(effects.events.isEmpty)

        #expect(tracker.finish(second, identity: identity, currentIdentity: identity))
        host.state.update()
        guard case .presented = await coordinator.evaluate(
            hostID: host.state.hostID, state: host.state, identity: identity,
            effects: effects.effects, host: host.callbacks
        ) else {
            Issue.record("The final token completion should make the retained request eligible")
            return
        }
        #expect(effects.events == ["seen-read", "refresh", "seen-reread"])
        #expect(host.bindCount == 1)
    }

    @Test("an admitted seen write holds the account claim until the write finishes")
    func committingWriteKeepsGlobalLock() async {
        let identity = accountIdentity()
        let first = TrialHostHarness(identity: identity)
        let second = TrialHostHarness(identity: identity)
        let coordinator = TrialIntroPresentationCoordinator()
        let effects = TrialEffectsHarness()
        let secondEffects = TrialEffectsHarness()
        let result = await coordinator.evaluate(hostID: first.state.hostID, state: first.state,
                                                identity: identity, effects: effects.effects,
                                                host: first.callbacks)
        guard case .presented(let claimID) = result else {
            Issue.record("Expected a presentation claim")
            return
        }
        let writeGate = AsyncTestGate()
        effects.writeGate = writeGate
        let appearance = Task { @MainActor in
            await coordinator.coverAppeared(claimID: claimID, hostID: first.state.hostID,
                                            state: first.state, host: first.callbacks,
                                            effects: effects.effects)
        }
        #expect(await writeGate.waitUntilEntered())

        first.identity = nil
        first.state.unregisterRoot()
        coordinator.retireHost(first.state.hostID)

        let blocked = await coordinator.evaluate(hostID: second.state.hostID, state: second.state,
                                                 identity: identity, effects: secondEffects.effects,
                                                 host: second.callbacks)
        #expect(blocked == .blockedByOtherClaim(claimID))
        #expect(secondEffects.events.isEmpty)

        await writeGate.open()
        #expect(await appearance.value == false)
        #expect(effects.seenWrites == [identity.userID])
        #expect(coordinator.claim(for: identity.userID) == nil)
    }

    @Test("already-seen and freshly paid-active results consume readiness without presenting")
    func terminalEligibilityConsumesPendingRequest() async {
        let identity = accountIdentity()
        let seenHost = TrialHostHarness(identity: identity)
        let seenEffects = TrialEffectsHarness()
        seenEffects.seenValues = [true]
        let coordinator = TrialIntroPresentationCoordinator()
        let seenOutcome = await coordinator.evaluate(hostID: seenHost.state.hostID, state: seenHost.state,
                                                     identity: identity, effects: seenEffects.effects,
                                                     host: seenHost.callbacks)
        #expect(seenOutcome == .alreadySeen)
        #expect(seenHost.state.pendingReadyIdentity == nil)
        #expect(seenHost.bindCount == 0)

        let paidHost = TrialHostHarness(identity: identity)
        let paidEffects = TrialEffectsHarness()
        paidEffects.refreshResult = .success(.readerActive(.init(periodEndMs: 1, remainingNarrationSeconds: 0,
                                                                 remainingVoiceChatSeconds: 0)))
        let paidOutcome = await coordinator.evaluate(hostID: paidHost.state.hostID, state: paidHost.state,
                                                     identity: identity, effects: paidEffects.effects,
                                                     host: paidHost.callbacks)
        #expect(paidOutcome == .ineligible)
        #expect(paidHost.state.pendingReadyIdentity == nil)
        #expect(paidHost.bindCount == 0)
        #expect(paidEffects.events == ["seen-read", "refresh"])
    }

    @Test("a stale host cannot present after its account generation changes during refresh")
    func generationChangeDuringRefreshPreventsCoverBinding() async {
        let identity = accountIdentity()
        let host = TrialHostHarness(identity: identity)
        let nextIdentity = LibraryAccountIdentity(userID: identity.userID, generation: identity.generation + 1)
        let gate = AsyncTestGate()
        let effects = TrialEffectsHarness(gateAt: "refresh", gate: gate)
        let coordinator = TrialIntroPresentationCoordinator()
        let evaluation = Task { @MainActor in
            await coordinator.evaluate(hostID: host.state.hostID, state: host.state,
                                       identity: identity, effects: effects.effects,
                                       host: host.callbacks)
        }
        #expect(await gate.waitUntilEntered())
        host.identity = nextIdentity
        host.state.requestLibraryReady(identity: nextIdentity)
        host.state.update()
        await gate.open()

        #expect(await evaluation.value == .factsChanged)
        #expect(host.bindCount == 0)
        #expect(effects.seenWrites.isEmpty)
        #expect(host.state.pendingReadyIdentity == nextIdentity)
    }
}

@MainActor
private final class TrialHostHarness {
    let state: TrialIntroPresentationState
    private let errorSource = NSObject()
    private let legacyTracker: TrialLegacySampleOperationTracker?
    var identity: LibraryAccountIdentity?
    var hostActive = true
    var sceneActive = true
    var rootPathEmpty = true
    var sharedReaderAbsent = true
    var catalystReaderWindowsAbsent = true
    var presentation: TrialRootPresentation = .none
    var competingRootModal = false
    var childModal = false
    var bindCount = 0
    var dismissedClaims: [UUID] = []

    init(identity: LibraryAccountIdentity, legacyTracker: TrialLegacySampleOperationTracker? = nil) {
        self.identity = identity
        self.legacyTracker = legacyTracker
        state = TrialIntroPresentationState()
        let bridge = state
        state.registerRoot { [weak self, bridge] in
            guard let self else {
                return TrialIntroPresentationSnapshot(
                    hostID: bridge.hostID, identity: nil, revision: bridge.currentRevision,
                    hostActive: false, sceneActive: false, rootPathEmpty: false,
                    sharedReaderAbsent: false, catalystReaderWindowsAbsent: false,
                    rootPresentation: .other, child: nil,
                    restoreActive: false, nativePresentationActive: false
                )
            }
            let claimID: UUID?
            if case .claimedTrialIntro(let id) = self.presentation {
                claimID = id
            } else {
                claimID = nil
            }
            return TrialIntroPresentationSnapshot(
                hostID: bridge.hostID, identity: self.identity, revision: bridge.currentRevision,
                hostActive: self.hostActive, sceneActive: self.sceneActive,
                rootPathEmpty: self.rootPathEmpty, sharedReaderAbsent: self.sharedReaderAbsent,
                catalystReaderWindowsAbsent: self.catalystReaderWindowsAbsent,
                rootPresentation: NoCardTrialPresentationPolicy.rootPresentation(
                    trialCoverPresented: claimID != nil,
                    trialClaimID: claimID,
                    competingPresentationActive: self.competingRootModal
                ), child: nil,
                restoreActive: false, nativePresentationActive: false
            )
        }
        state.registerPurchaseError(source: errorSource) { false }
        for source in [TrialIntroPresentationState.Source.signedIn, .signedInContent, .library, .libraryRoot] {
            state.register(source, identity: identity) { [weak self] in
                guard let self else { return nil }
                return TrialChildSafety(signedIn: true, consent: true, conversation: true,
                                        voice: true, libraryReady: true,
                                        libraryModal: !self.childModal,
                                        firstBookFlowActive: self.legacyTracker?.isActive(for: identity) ?? false)
            }
        }
        state.requestLibraryReady(identity: identity)
    }

    var callbacks: TrialIntroPresentationCoordinator.Host {
        TrialIntroPresentationCoordinator.Host(
            snapshot: { [weak self] in self?.state.snapshot() },
            bindCover: { [weak self] claimID in
                guard let self else { return false }
                self.bindCount += 1
                self.presentation = .claimedTrialIntro(claimID)
                self.state.setOwnedCover(claimID)
                self.state.update()
                return true
            },
            dismissCover: { [weak self] claimID in
                guard let self else { return }
                self.dismissedClaims.append(claimID)
                if self.presentation == .claimedTrialIntro(claimID) {
                    self.presentation = .none
                    self.state.setOwnedCover(nil)
                    self.state.coverDidDismiss(claimID: claimID)
                }
                self.state.update()
            }
        )
    }
}

@MainActor
private final class TrialEffectsHarness {
    var events: [String] = []
    var seenWrites: [UUID] = []
    var seenValues: [Bool] = [false, false]
    var gateAt: String?
    var gate: AsyncTestGate?
    var writeGate: AsyncTestGate?
    var refreshResult: Result<EntitlementSnapshot, Error>?
    private var seenReadIndex = 0

    init(seenGate: AsyncTestGate? = nil) {
        gateAt = seenGate == nil ? nil : "seen-read"
        gate = seenGate
    }
    init(gateAt: String, gate: AsyncTestGate) {
        self.gateAt = gateAt
        self.gate = gate
    }

    var effects: TrialIntroPresentationCoordinator.Effects {
        TrialIntroPresentationCoordinator.Effects(
            hasSeen: { [weak self] _ in
                guard let self else { return false }
                self.seenReadIndex += 1
                let label = self.seenReadIndex == 1 ? "seen-read" : "seen-reread"
                self.events.append(label)
                await self.pauseIfNeeded(label)
                let index = min(self.seenReadIndex - 1, self.seenValues.count - 1)
                return self.seenValues[index]
            },
            refreshEntitlement: { [weak self] in
                guard let self else { return nil }
                self.events.append("refresh")
                await self.pauseIfNeeded("refresh")
                return self.refreshResult
            },
            setSeenTrue: { [weak self] userID in
                guard let self else { return }
                self.seenWrites.append(userID)
                await self.writeGate?.wait()
            }
        )
    }

    private func pauseIfNeeded(_ step: String) async {
        guard gateAt == step, let gate else { return }
        await gate.wait()
    }
}

private actor AsyncTestGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func wait() async -> Bool {
        entered = true
        entryWaiters.values.forEach { $0.resume(returning: true) }
        entryWaiters.removeAll()
        if opened { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if opened {
                    continuation.resume(returning: true)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func waitUntilEntered() async -> Bool {
        if entered { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitForEntry() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let reached = await group.next() ?? false
            group.cancelAll()
            if !reached { await self.open() }
            return reached
        }
    }

    func open() {
        opened = true
        waiters.values.forEach { $0.resume(returning: true) }
        waiters.removeAll()
    }

    private func waitForEntry() async -> Bool {
        if entered { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if entered {
                    continuation.resume(returning: true)
                } else {
                    entryWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelEntryWaiter(id) }
        }
    }

    private func cancelEntryWaiter(_ id: UUID) {
        entryWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }
}

private func accountIdentity() -> LibraryAccountIdentity {
    LibraryAccountIdentity(userID: UUID(), generation: 1)
}
