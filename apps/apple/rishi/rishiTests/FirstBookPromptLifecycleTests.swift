@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("First book prompt lifecycle")
struct FirstBookPromptLifecycleTests {
    @Test("dedicated first book override bypasses only generic fixtures")
    func genericFixtureFlagMatrix() {
        #expect(FirstBookUITestFixturePolicy.usesGenericFixtures(environment: ["RISHI_UITEST": "1"]))
        #expect(!FirstBookUITestFixturePolicy.usesGenericFixtures(environment: [
            "RISHI_UITEST": "1", "RISHI_UITEST_FIRST_BOOK_PROMPT": "1"
        ]))
        #expect(!FirstBookUITestFixturePolicy.usesGenericFixtures(environment: ["RISHI_UITEST_FIRST_BOOK_PROMPT": "1"]))
        #expect(!FirstBookUITestFixturePolicy.usesGenericFixtures(environment: [:]))
        #expect(FirstBookSampleFailurePresentation.retryableMessage == "We couldn’t prepare the sample. Try again or import your own book.")
    }

    @Test("host admission revokes synchronously and stale retirement cannot revoke replacement")
    func hostRetirementIsExactAndSynchronous() {
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 2)
        let hostID = UUID()
        let state = TrialIntroPresentationState(hostID: hostID)
        state.registerRoot { rootSnapshot(identity: identity, hostID: hostID) }
        let authority = TrialRootLifetimeAuthority()
        let old = authority.register(hostID: hostID, graphID: UUID(), sceneID: UUID())
        state.installHostLifetime(old, isCurrent: { authority.isCurrent($0) })
        let oldAdmission = FirstBookPromptHostAdmission(identity: identity, hostToken: old)
        var revocations = 0
        let observer = state.observeHostRetirement(old) { oldAdmission.revoke(); revocations += 1 }
        #expect(observer != nil)
        #expect(oldAdmission.isCurrent(state: state, currentIdentity: identity))

        #expect(authority.retire(old))
        state.retireHostLifetime(old)
        #expect(revocations == 1)
        #expect(oldAdmission.isCurrent(state: state, currentIdentity: identity) == false)

        let replacement = authority.register(hostID: hostID, graphID: UUID(), sceneID: UUID())
        state.installHostLifetime(replacement, isCurrent: { authority.isCurrent($0) })
        #expect(state.isHostLifetimeCurrent(replacement, identity: identity))
        state.retireHostLifetime(old)
        #expect(state.isHostLifetimeCurrent(replacement, identity: identity))
    }

    @Test("native dismissal receipt is consumed once and preserves its exact reason")
    func dismissalReceiptIsOneShot() {
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 4)
        let hostToken = TrialRootLifetimeAuthority.Anchor(
            registrationID: UUID(), hostID: UUID(), graphID: UUID(), sceneID: UUID()
        )
        let coordinator = FirstBookSampleCoordinator(
            identity: identity,
            install: { throw CancellationError() },
            acquireLease: { _ in throw CancellationError() },
            ensureReady: { _ in },
            isCurrentIdentity: { _ in false },
            persistRecovery: { _ in }, dismiss: {}, markSeen: { _ in },
            requestTour: { _, _ in }, openBook: { _ in false },
            hasOwnedReaderWindow: { _ in false }, clearTourRequest: { _, _ in }, clearRecovery: { _ in }
        )
        let admission = FirstBookPromptHostAdmission(identity: identity, hostToken: hostToken)
        let receipt = FirstBookPromptDismissalReceipt(identity: identity, coordinator: coordinator, admission: admission)
        let attemptID = UUID()
        receipt.reason = .sample(attemptID)
        #expect(receipt.reason == .sample(attemptID))
        #expect(receipt.consumeForNativeDismissal() == .sample(attemptID))
        #expect(receipt.consumeForNativeDismissal() == nil)

        let skipReceipt = FirstBookPromptDismissalReceipt(
            identity: identity, coordinator: coordinator, admission: admission
        )
        skipReceipt.reason = .explicitSkip
        #expect(skipReceipt.consumeForNativeDismissal() == .explicitSkip)
        #expect(skipReceipt.consumeForNativeDismissal() == nil)

        let importAttempt = UUID()
        let importReceipt = FirstBookPromptDismissalReceipt(
            identity: identity, coordinator: coordinator, admission: admission
        )
        importReceipt.reason = .import(importAttempt)
        #expect(importReceipt.consumeForNativeDismissal() == .import(importAttempt))
    }

    @Test("explicit Skip clears persisted recovery across content and native callback orderings")
    func skipPersistsClearAndNativeBoundaryCompletesOnce() async throws {
        for contentDisappearsFirst in [true, false] {
            let defaults = try makeLifecycleDefaults()
            defer { defaults.0.removePersistentDomain(forName: defaults.1) }
            let harness = try PromptLifecycleHarness(defaults: defaults.0)
            let receipt = harness.beginPrompt()
            let duplicate = FirstBookPromptDismissalReceipt(
                identity: harness.identity, coordinator: harness.coordinator, admission: harness.admission
            )
            #expect(!harness.admission.beginPresentation(duplicate))
            #expect(harness.admission.activeReceipt === receipt)
            let store = FirstBookRecoveryStore(defaults: defaults.0)
            let identity = harness.identity

            let didDismiss = await harness.admission.performExplicitSkip(
                receipt,
                isCurrent: { harness.isCurrent },
                persistPending: { store.setRecovery(true, identity: identity, currentIdentity: harness.currentIdentity) },
                skip: { await harness.coordinator.skip() },
                dismiss: { exact in _ = harness.admission.captureNativeDismissal(exact) }
            )

            #expect(didDismiss)
            #expect(!store.hasRecovery(userID: identity.userID))
            if contentDisappearsFirst { harness.admission.contentDidDisappear(receipt) }
            #expect(harness.probe.openCount == 0)
            #expect(harness.probe.readyCount == 0) // content disappearance alone is not native dismissal
            let outcome = await harness.admission.performNativeDismissal(
                receipt,
                isCurrent: { harness.isCurrent },
                skip: { await harness.coordinator.skip() },
                completeSample: { await harness.coordinator.completeDismissal() },
                requestReady: { _ in harness.probe.readyCount += 1; return true }
            )
            if !contentDisappearsFirst { harness.admission.contentDidDisappear(receipt) }

            #expect(outcome == .completed)
            #expect(harness.probe.readyCount == 1)
            #expect(harness.probe.openCount == 0)
            #expect(!store.hasRecovery(userID: identity.userID))
            #expect(await harness.admission.performNativeDismissal(
                receipt,
                isCurrent: { harness.isCurrent },
                skip: {}, completeSample: {}, requestReady: { _ in harness.probe.readyCount += 1; return true }
            ) == .ignored)
            #expect(harness.probe.readyCount == 1)
        }
    }

    @Test("failed ready handoff reopens the same coordinator and Retry completes at the next native dismissal")
    func failedOpenRecoveryKeepsSessionForRetry() async throws {
        let defaults = try makeLifecycleDefaults()
        defer { defaults.0.removePersistentDomain(forName: defaults.1) }
        let harness = try PromptLifecycleHarness(defaults: defaults.0, openResults: [false, true])
        let firstReceipt = harness.beginPrompt()

        await harness.coordinator.selectSample()
        #expect(firstReceipt.reason == .sample(harness.coordinator.attemptID!))
        let firstOutcome = await harness.admission.performNativeDismissal(
            firstReceipt,
            isCurrent: { harness.isCurrent },
            skip: { await harness.coordinator.skip() },
            completeSample: { await harness.coordinator.completeDismissal() },
            requestReady: { _ in harness.probe.readyCount += 1; return true }
        )
        #expect(firstOutcome == .retryableFailure)
        #expect(harness.coordinator.state == .failed)
        #expect(harness.coordinator.failureKind == .retryable)
        #expect(!harness.admission.completed)

        let retryReceipt = harness.beginPrompt()
        #expect(retryReceipt !== firstReceipt)
        #expect(retryReceipt.coordinator === harness.coordinator)
        #expect(!harness.admission.captureNativeDismissal(firstReceipt))
        #expect(await harness.admission.performNativeDismissal(
            firstReceipt,
            isCurrent: { harness.isCurrent },
            skip: {}, completeSample: {}, requestReady: { _ in harness.probe.readyCount += 1; return true }
        ) == .ignored)
        #expect(harness.admission.activeReceipt === retryReceipt)
        await harness.coordinator.retry()
        guard case .sample = retryReceipt.reason else { Issue.record("Retry did not capture its own sample dismissal") ; return }
        let secondOutcome = await harness.admission.performNativeDismissal(
            retryReceipt,
            isCurrent: { harness.isCurrent },
            skip: { await harness.coordinator.skip() },
            completeSample: { await harness.coordinator.completeDismissal() },
            requestReady: { _ in harness.probe.readyCount += 1; return true }
        )
        #expect(secondOutcome == .completed)
        #expect(harness.probe.openCount == 2)
        #expect(harness.probe.readyCount == 1)
        #expect(harness.admission.completed)
    }

    @Test("duplicate and consumed native receipts cannot finish an in-flight dismissal")
    func nativeDismissalIsOwnedUntilItsAwaitResumes() async throws {
        let defaults = try makeLifecycleDefaults()
        defer { defaults.0.removePersistentDomain(forName: defaults.1) }
        let harness = try PromptLifecycleHarness(defaults: defaults.0, openResults: [false, true])
        let firstReceipt = harness.beginPrompt()
        await harness.coordinator.selectSample()
        let failed = await harness.admission.performNativeDismissal(
            firstReceipt, isCurrent: { harness.isCurrent }, skip: {},
            completeSample: { await harness.coordinator.completeDismissal() }, requestReady: { _ in true }
        )
        #expect(failed == .retryableFailure)

        let receipt = harness.beginPrompt()
        await harness.coordinator.retry()
        let gate = PromptLifecycleGate()
        let completion = Task { @MainActor in
            await harness.admission.performNativeDismissal(
                receipt, isCurrent: { harness.isCurrent }, skip: {},
                completeSample: {
                    await gate.suspend()
                    await harness.coordinator.completeDismissal()
                },
                requestReady: { _ in harness.probe.readyCount += 1; return true }
            )
        }
        await gate.waitUntilEntered()
        #expect(harness.admission.dismissalInFlight)
        #expect(harness.admission.dismissalReceipt === receipt)

        let duplicate = await harness.admission.performNativeDismissal(
            receipt, isCurrent: { harness.isCurrent }, skip: {}, completeSample: {}, requestReady: { _ in false }
        )
        let stale = await harness.admission.performNativeDismissal(
            firstReceipt, isCurrent: { harness.isCurrent }, skip: {}, completeSample: {}, requestReady: { _ in false }
        )
        #expect(duplicate == .ignored)
        #expect(stale == .ignored)
        #expect(harness.admission.dismissalInFlight)
        #expect(harness.admission.dismissalReceipt === receipt)
        #expect(!harness.admission.completed)

        await gate.resume()
        #expect(await completion.value == .completed)
        #expect(harness.probe.openCount == 2)
        #expect(harness.probe.readyCount == 1)
        #expect(harness.admission.completed)
    }

    @Test("host retirement during Skip await cancels the exact prompt action")
    func retirementDuringSkipAwaitBlocksDismissal() async throws {
        let defaults = try makeLifecycleDefaults()
        defer { defaults.0.removePersistentDomain(forName: defaults.1) }
        let harness = try PromptLifecycleHarness(defaults: defaults.0)
        let receipt = harness.beginPrompt()
        let gate = PromptLifecycleGate()
        var skipEffects = 0
        var dismissals = 0
        var skipResult: Bool?
        let skipTask = Task { @MainActor in
            skipResult = await harness.admission.performExplicitSkip(
                receipt,
                isCurrent: { harness.isCurrent },
                persistPending: { harness.store.setRecovery(true, identity: harness.identity, currentIdentity: harness.currentIdentity) },
                skip: {
                    await gate.suspend()
                    guard !Task.isCancelled else { return }
                    skipEffects += 1
                    await harness.coordinator.skip()
                },
                dismiss: { _ in dismissals += 1 }
            )
        }
        harness.admission.lifecycleTask = skipTask
        await gate.waitUntilEntered()
        let replacement = harness.authority.register(hostID: harness.state.hostID, graphID: UUID(), sceneID: UUID())
        harness.state.installHostLifetime(replacement, isCurrent: { harness.authority.isCurrent($0) })
        #expect(harness.admission.revoked)
        await gate.resume()
        await skipTask.value
        #expect(skipResult == false)
        #expect(skipEffects == 0)
        #expect(dismissals == 0)
        #expect(harness.probe.openCount == 0)
        harness.admission.cleanupRetiredOwner()
    }

    @Test("prompt picker readiness is owned through native completion and retirement")
    func pickerReadinessWaitsForOwnedCompletion() async throws {
        let defaults = try makeLifecycleDefaults()
        defer { defaults.0.removePersistentDomain(forName: defaults.1) }
        let harness = try PromptLifecycleHarness(defaults: defaults.0)
        let receipt = harness.beginPrompt()
        receipt.reason = .import(UUID())
        #expect(harness.admission.captureNativeDismissal(receipt))
        let pickerOutcome = await harness.admission.performNativeDismissal(
            receipt, isCurrent: { harness.isCurrent }, skip: {}, completeSample: {},
            requestReady: { exact in
                #expect(exact === receipt)
                harness.probe.readyCount += 1
                return true
            }
        )
        #expect(pickerOutcome == .importPresented)
        #expect(harness.admission.pickerReceipt === receipt)
        #expect(harness.admission.pickerCloseAction(recoveryPending: false) == .waitForOwnedTerminal)
        // Empty/cancelled/unsupported terminal can arrive before or after picker close.
        // Once it marks recovery pending, the close callback must drain safe reopen first.
        #expect(harness.admission.pickerCloseAction(recoveryPending: true) == .reopenRecovery)

        let gate = PromptLifecycleGate()
        var readinessEffects = 0
        var readinessResult: Bool?
        let readiness = Task { @MainActor in
            readinessResult = await harness.admission.performOwnedReadiness(
                for: receipt,
                isCurrent: { harness.isCurrent },
                requestReadiness: {
                    await gate.suspend()
                    return true
                },
                publishReadiness: {
                    readinessEffects += 1
                    return true
                }
            )
        }
        harness.admission.lifecycleTask = readiness
        await gate.waitUntilEntered()
        let replacement = harness.authority.register(hostID: harness.state.hostID, graphID: UUID(), sceneID: UUID())
        harness.state.installHostLifetime(replacement, isCurrent: { harness.authority.isCurrent($0) })
        let replacementAdmission = FirstBookPromptHostAdmission(identity: harness.identity, hostToken: replacement)
        let replacementCoordinator = harness.makeSpareCoordinator()
        replacementAdmission.coordinator = replacementCoordinator
        let replacementReceipt = FirstBookPromptDismissalReceipt(
            identity: harness.identity, coordinator: replacementCoordinator, admission: replacementAdmission
        )
        #expect(replacementAdmission.beginPresentation(replacementReceipt))
        await gate.resume()
        await readiness.value
        #expect(readinessResult == false)
        #expect(readinessEffects == 0)
        #expect(harness.admission.pickerReceipt === receipt)
        #expect(replacementAdmission.activeReceipt === replacementReceipt)
        #expect(replacementAdmission.isCurrent(state: harness.state, currentIdentity: harness.identity))
        harness.admission.cleanupRetiredOwner()
        #expect(replacementAdmission.activeReceipt === replacementReceipt)
    }

    @Test("retirement releases the captured old owner while preserving replacement and transient host states")
    func retirementCleanupIsOwnerScoped() async throws {
        let defaults = try makeLifecycleDefaults()
        defer { defaults.0.removePersistentDomain(forName: defaults.1) }
        let harness = try PromptLifecycleHarness(defaults: defaults.0)
        let oldReceipt = harness.beginPrompt()
        await harness.coordinator.selectSample()
        #expect(harness.coordinator.state == .ready(harness.book))
        #expect(harness.probe.releaseCount.value == 0)

        let oldAnchor = harness.admission.hostToken
        let coverClaim = UUID()
        harness.state.setOwnedCover(coverClaim)
        #expect(harness.authority.setSceneActive(oldAnchor, active: false))
        #expect(harness.authority.retainAfterTransientWindowDetach(oldAnchor))
        #expect(harness.admission.isCurrent(state: harness.state, currentIdentity: harness.identity))

        let gate = PromptLifecycleGate()
        var acceptanceEffects = 0
        var acceptedCallbacks = 0
        var retiredCallbacks = 0
        let adapter = FirstPromptImportAdapter(
            attemptID: UUID(), identity: harness.identity,
            isCurrent: { harness.isCurrent }, onLifecycle: { _ in },
            acceptCandidate: { _ in
                await gate.suspend()
                guard !Task.isCancelled else { return false }
                acceptanceEffects += 1
                return true
            },
            onAccepted: { _ in acceptedCallbacks += 1 },
            onTerminated: { accepted in if !accepted { retiredCallbacks += 1 } }
        )
        harness.admission.adapter = adapter
        adapter.began(supportedCount: 1)
        adapter.registered(ImportCoordinator.ImportOutcome(
            url: URL(fileURLWithPath: "/tmp/first-book-lifecycle-import.epub"),
            book: harness.book, error: nil
        ))
        await gate.waitUntilEntered()
        let capturedAcceptanceTask = adapter.acceptanceTask
        #expect(capturedAcceptanceTask != nil)

        #expect(harness.authority.sceneDidDisconnect(anchor: oldAnchor, sceneID: oldAnchor.sceneID))
        harness.state.retireHostLifetime(oldAnchor)
        #expect(harness.admission.revoked)
        let replacementToken = harness.authority.register(hostID: harness.state.hostID, graphID: UUID(), sceneID: UUID())
        harness.state.installHostLifetime(replacementToken, isCurrent: { harness.authority.isCurrent($0) })
        let replacement = FirstBookPromptHostAdmission(identity: harness.identity, hostToken: replacementToken)
        let replacementCoordinator = harness.makeSpareCoordinator()
        replacement.coordinator = replacementCoordinator
        var replacementTerminalCallbacks = 0
        let replacementAdapter = FirstPromptImportAdapter(
            attemptID: UUID(), identity: harness.identity,
            isCurrent: { replacement.isCurrent(state: harness.state, currentIdentity: harness.currentIdentity) },
            onLifecycle: { _ in }, acceptCandidate: { _ in true }, onAccepted: { _ in },
            onTerminated: { _ in replacementTerminalCallbacks += 1 }
        )
        replacement.adapter = replacementAdapter

        await gate.resume()
        await capturedAcceptanceTask?.value
        #expect(acceptanceEffects == 0)
        #expect(acceptedCallbacks == 0)
        #expect(harness.authority.setSceneActive(replacementToken, active: false))
        harness.rootPresentation = false
        #expect(harness.state.isHostLifetimeCurrent(replacementToken, identity: harness.identity))
        harness.rootPresentation = true
        #expect(harness.authority.retainAfterTransientWindowDetach(replacementToken))
        #expect(replacement.isCurrent(state: harness.state, currentIdentity: harness.identity))
        #expect(!harness.admission.isCurrent(state: harness.state, currentIdentity: harness.identity))
        #expect(harness.admission.isCurrent(state: harness.state, currentIdentity: harness.identity) == false)
        harness.admission.cleanupRetiredOwner()
        harness.admission.cleanupRetiredOwner()

        #expect(harness.probe.releaseCount.value == 1)
        #expect(retiredCallbacks == 1)
        #expect(replacement.coordinator === replacementCoordinator)
        #expect(replacementCoordinator.state == .choosing)
        #expect(!replacementAdapter.wasRetired)
        #expect(replacementTerminalCallbacks == 0)
        #expect(replacement.isCurrent(state: harness.state, currentIdentity: harness.identity))
        #expect(harness.admission.retiredCleanupComplete)
        #expect(oldReceipt.coordinator === harness.coordinator)
        #expect(harness.probe.tourCount == 0)
    }
}

@MainActor
private final class PromptLifecycleHarness {
    let identity = LibraryAccountIdentity(userID: UUID(), generation: 5)
    let state: TrialIntroPresentationState
    let authority = TrialRootLifetimeAuthority()
    let admission: FirstBookPromptHostAdmission
    let store: FirstBookRecoveryStore
    let probe: PromptLifecycleProbe
    let book: Book
    private let rootPresentationFlag: PromptRootPresentationFlag
    var currentIdentity: LibraryAccountIdentity?
    var rootPresentation: Bool {
        get { rootPresentationFlag.value }
        set { rootPresentationFlag.value = newValue }
    }
    var coordinator: FirstBookSampleCoordinator!
    private(set) var receipt: FirstBookPromptDismissalReceipt?

    var isCurrent: Bool {
        admission.isCurrent(state: state, currentIdentity: currentIdentity)
    }

    init(defaults: UserDefaults, openResults: [Bool] = [true]) throws {
        let hostID = UUID()
        state = TrialIntroPresentationState(hostID: hostID)
        store = FirstBookRecoveryStore(defaults: defaults)
        probe = PromptLifecycleProbe(openResults: openResults)
        book = Book(userId: identity.userID, title: "Sample", formatType: .epub, fileURL: "Books/sample.epub")
        let rootFlag = PromptRootPresentationFlag()
        rootPresentationFlag = rootFlag
        currentIdentity = identity
        state.registerRoot { [identity, state, rootFlag] in
            var snapshot = rootSnapshot(identity: identity, hostID: state.hostID)
            snapshot.rootPathEmpty = rootFlag.value
            return snapshot
        }
        let token = authority.register(hostID: hostID, graphID: UUID(), sceneID: UUID())
        state.installHostLifetime(token, isCurrent: { [authority] in authority.isCurrent($0) })
        admission = FirstBookPromptHostAdmission(identity: identity, hostToken: token)
        coordinator = makeCoordinator()
        admission.coordinator = coordinator
        let ownedAdmission = admission
        admission.retirementObserverID = state.observeHostRetirement(token) {
            ownedAdmission.retireSynchronously()
        }
    }

    func beginPrompt() -> FirstBookPromptDismissalReceipt {
        let receipt = FirstBookPromptDismissalReceipt(identity: identity, coordinator: coordinator, admission: admission)
        #expect(admission.beginPresentation(receipt))
        self.receipt = receipt
        return receipt
    }

    func makeSpareCoordinator() -> FirstBookSampleCoordinator {
        let book = self.book
        let generation = identity.generation
        let releaseCount = probe.releaseCount
        return FirstBookSampleCoordinator(
            identity: identity,
            install: { book },
            acquireLease: { candidate in try makeLifecycleLease(book: candidate, generation: generation, releaseCount: releaseCount) },
            ensureReady: { _ in }, isCurrentIdentity: { _ in true }, persistRecovery: { _ in }, dismiss: {},
            markSeen: { _ in }, requestTour: { _, _ in }, openBook: { _ in true },
            hasOwnedReaderWindow: { _ in false }, clearTourRequest: { _, _ in }, clearRecovery: { _ in }
        )
    }

    private func makeCoordinator() -> FirstBookSampleCoordinator {
        let book = self.book
        let generation = identity.generation
        let releaseCount = probe.releaseCount
        return FirstBookSampleCoordinator(
            identity: identity,
            install: { book },
            acquireLease: { candidate in try makeLifecycleLease(book: candidate, generation: generation, releaseCount: releaseCount) },
            ensureReady: { _ in },
            isCurrentIdentity: { expected in self.isCurrent && expected == self.identity },
            persistRecovery: { captured in
                self.store.setRecovery(true, identity: captured, currentIdentity: self.currentIdentity, isCancelled: Task.isCancelled)
            },
            dismiss: {
                guard let receipt = self.receipt,
                      let attemptID = self.coordinator?.attemptID else { return }
                receipt.reason = .sample(attemptID)
                _ = self.admission.captureNativeDismissal(receipt)
            },
            markSeen: { _ in self.probe.seenCount += 1 },
            requestTour: { _, _ in self.probe.tourCount += 1 },
            openBook: { _ in self.probe.open() },
            hasOwnedReaderWindow: { _ in false },
            clearTourRequest: { _, _ in self.probe.tourClearCount += 1 },
            clearRecovery: { captured in
                self.store.setRecovery(false, identity: captured, currentIdentity: self.currentIdentity, isCancelled: Task.isCancelled)
            }
        )
    }
}

@MainActor
private final class PromptLifecycleProbe {
    private var openResults: [Bool]
    var openCount = 0
    var readyCount = 0
    var seenCount = 0
    var tourCount = 0
    var tourClearCount = 0
    let releaseCount = LockedPromptCounter()

    init(openResults: [Bool]) { self.openResults = openResults }

    func open() -> Bool {
        openCount += 1
        return openResults.isEmpty ? true : openResults.removeFirst()
    }
}

private final class LockedPromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private func makeLifecycleDefaults() throws -> (UserDefaults, String) {
    let suite = "rishi-first-book-lifecycle-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw LifecycleTestError.defaults }
    return (defaults, suite)
}

private func makeLifecycleLease(book: Book, generation: UInt64, releaseCount: LockedPromptCounter) throws -> BookSourceLease {
    let permit = BookSourceAccessPermit()
    let authority = BookSourceEffectAuthority()
    authority.register(permit)
    let readingPermit = BookReadingPermit(
        ownerID: book.userId,
        accountGeneration: generation,
        bookID: book.id,
        contentRevision: UUID()
    )
    let owner = try BookSourceOwner(
        url: URL(fileURLWithPath: "/tmp/first-book-lifecycle.epub"),
        access: .account(readingPermit),
        sourceAccessPermit: permit,
        effectAuthority: authority
    )
    return BookSourceLease(owner: owner, cachePolicy: .transient, release: { releaseCount.increment() })
}

private enum LifecycleTestError: Error { case defaults }

@MainActor
private final class PromptLifecycleGate {
    private var entered = false
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        enterWaiter?.resume()
        enterWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enterWaiter = $0 }
    }

    func resume() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class PromptRootPresentationFlag {
    var value = true
}
