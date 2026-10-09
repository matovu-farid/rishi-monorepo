import Foundation
import Observation

/// The account-keyed library host owns this alongside its existing row model.
/// Readiness, sync waves and prewarm retain one captured startup attempt.
@MainActor
@Observable
final class LibraryStartupModel {
    struct Intent: Identifiable {
        enum Kind: Equatable { case firstBookPrompt, recoveryPrompt, trialReady }
        let id = UUID()
        let identity: LibraryAccountIdentity
        let attemptID: UUID
        let kind: Kind
        let markFirstBookPromptSeen: Bool
    }

    struct FirstBookFacts: Equatable {
        var hasSeenPrompt: Bool
        var recoveryPending: Bool
        var documentPickerPresented: Bool
        var firstPromptImportActive: Bool
    }

    private struct Attempt {
        let id = UUID()
        var armed = false
        var recoveryClaimed = false
        var waveID: UUID?
        var snapshotRead = false
        var completionObserved = false
        var snapshotFailed = false
        var fallbackStarted = false
    }

    private(set) var intent: Intent?
    let identity: LibraryAccountIdentity
    private let library: LibraryViewModel
    private let currentIdentity: @MainActor () -> LibraryAccountIdentity?
    private let sync: @MainActor (@escaping @MainActor @Sendable (UUID) async -> Void) async -> Void
    private let prewarm: @MainActor ([BookID]) async -> Void
    private let prepareInitialSnapshot: @MainActor () async -> Void
    private let suppressFirstBookPrompt: Bool
    private var facts = FirstBookFacts(hasSeenPrompt: false, recoveryPending: false,
                                     documentPickerPresented: false, firstPromptImportActive: false)
    private var attempt: Attempt?
    private var activeAttemptID: UUID?
    private var handledInitialWaveID: UUID?
    private var handledRecoveryWaveID: UUID?
    private var completedInitialLoad = false
    private var trialReadinessRequested = false
    private var trialPromptSeenRequested = false
    private var retired = false

    init(
        identity: LibraryAccountIdentity,
        library: LibraryViewModel,
        currentIdentity: @escaping @MainActor () -> LibraryAccountIdentity?,
        sync: @escaping @MainActor (@escaping @MainActor @Sendable (UUID) async -> Void) async -> Void,
        prewarm: @escaping @MainActor ([BookID]) async -> Void,
        prepareInitialSnapshot: @escaping @MainActor () async -> Void = {},
        suppressFirstBookPrompt: Bool = false
    ) {
        self.identity = identity
        self.library = library
        self.currentIdentity = currentIdentity
        self.sync = sync
        self.prewarm = prewarm
        self.prepareInitialSnapshot = prepareInitialSnapshot
        self.suppressFirstBookPrompt = suppressFirstBookPrompt
    }

    var currentAttemptID: UUID? { activeAttemptID }

    func isCurrentAttempt(_ attemptID: UUID) -> Bool { isCurrent(attemptID) }

    func updateFirstBookFacts(_ facts: FirstBookFacts) {
        self.facts = facts
        if facts.documentPickerPresented || facts.firstPromptImportActive {
            if intent?.kind == .trialReady {
                trialReadinessRequested = true
                trialPromptSeenRequested = trialPromptSeenRequested || intent?.markFirstBookPromptSeen == true
                intent = nil
            }
        } else {
            publishRequestedTrialIfReady()
        }
    }

    func takeIntent(id: UUID) -> Intent? {
        guard let current = intent, current.id == id,
              isCurrent(current.attemptID), library.loadReadiness == .success(identity) else { return nil }
        if current.kind == .trialReady {
            guard !facts.documentPickerPresented, !facts.firstPromptImportActive else { return nil }
            trialReadinessRequested = false
            trialPromptSeenRequested = false
        }
        intent = nil
        return current
    }

    /// Removes a first-book or recovery prompt that an incoming document has
    /// made obsolete. Trial readiness is deliberately not superseded here.
    @discardableResult
    func supersedeFirstBookIntent(identity: LibraryAccountIdentity, attemptID: UUID) -> Bool {
        guard identity == self.identity, isCurrent(attemptID),
              let intent, intent.identity == identity, intent.attemptID == attemptID else { return false }
        guard intent.kind == .firstBookPrompt || intent.kind == .recoveryPrompt else { return false }
        self.intent = nil
        return true
    }

    /// Reissues a dismissed first-book/recovery prompt after an incoming
    /// import fails, but only while the original empty-library attempt lives.
    @discardableResult
    func restorePromptAfterIncomingFailure(
        identity: LibraryAccountIdentity, attemptID: UUID, kind: Intent.Kind
    ) -> Bool {
        guard identity == self.identity, isCurrent(attemptID),
              library.loadReadiness == .success(identity), library.books.isEmpty,
              !facts.documentPickerPresented, !facts.firstPromptImportActive,
              intent == nil else { return false }
        guard kind == .firstBookPrompt || kind == .recoveryPrompt else { return false }
        publish(kind, attemptID: attemptID, markSeen: kind == .recoveryPrompt && suppressFirstBookPrompt)
        return intent?.attemptID == attemptID && intent?.kind == kind
    }

    func cancelTrialReadiness() {
        trialReadinessRequested = false
        trialPromptSeenRequested = false
        if intent?.kind == .trialReady { intent = nil }
    }

    func retire() {
        retired = true
        activeAttemptID = nil
        attempt = nil
        intent = nil
        trialReadinessRequested = false
        trialPromptSeenRequested = false
    }

    func load(consentGranted: Bool, autoSync: Bool) async {
        guard !retired, currentIdentity() == identity, !Task.isCancelled else { return }
        let next = Attempt()
        attempt = next
        activeAttemptID = next.id
        intent = nil
        // The consent-keyed host can reload while picker/import presentation
        // blocks an admitted trial request. Preserve that semantic queue;
        // the new attempt must establish readiness before publishing it.
        await prepareInitialSnapshot()
        guard isCurrent(next.id) else { return }
        let result = await library.loadInitialSnapshotAndSyncIfNeeded(
            accountIdentity: identity, consentGranted: consentGranted, autoSync: autoSync,
            sync: { [self] in
                await sync { [weak self] waveID in
                    guard let self, self.isCurrent(next.id), self.attempt?.id == next.id else { return }
                    self.attempt?.waveID = waveID
                }
            }
        )
        guard isCurrent(next.id), attempt?.id == next.id else { return }
        attempt?.armed = true
        let snapshotReady = await revalidate(result: result, attemptID: next.id)
        guard isCurrent(next.id), attempt?.id == next.id else { return }
        if !snapshotReady {
            if result == .failure {
                guard attempt?.waveID != nil else { return }
                attempt?.snapshotFailed = true
                if attempt?.completionObserved == true, attempt?.fallbackStarted == false,
                   let waveID = attempt?.waveID {
                    attempt?.fallbackStarted = true
                    let fallback = await library.refresh()
                    _ = await resumeReadiness(result: fallback, attemptID: next.id, completedBy: waveID)
                }
            } else {
                clearInitialWave(attemptID: next.id)
                if library.loadReadiness == .success(identity) {
                    _ = await resumeReadiness(result: .success, attemptID: next.id, completedBy: nil)
                }
            }
            return
        }
        guard !completedInitialLoad else {
            clearAttempt(attemptID: next.id, completedBy: nil)
            return
        }
        attempt?.snapshotRead = true
        if attempt?.completionObserved == true {
            handledInitialWaveID = attempt?.waveID
            clearInitialWave(attemptID: next.id)
        }
        await prewarm(library.books.map(\.id))
        guard isCurrent(next.id), attempt?.id == next.id else { return }
        guard await revalidate(result: result, attemptID: next.id), isCurrent(next.id) else {
            if isCurrent(next.id), library.loadReadiness == .success(identity) {
                _ = await resumeReadiness(result: .success, attemptID: next.id, completedBy: nil)
            }
            return
        }
        _ = finishReadiness(attemptID: next.id, completedBy: nil)
    }

    func syncCompleted(waveID: UUID) async {
        guard let capturedID = activeAttemptID, isCurrent(capturedID),
              handledInitialWaveID != waveID, handledRecoveryWaveID != waveID else { return }
        if attempt?.waveID == waveID {
            if attempt?.snapshotFailed == true {
                guard attempt?.fallbackStarted == false else { return }
                attempt?.completionObserved = true
                attempt?.fallbackStarted = true
            } else if attempt?.snapshotRead == false {
                // The native initial loader still owns its post-sync read.
                attempt?.completionObserved = true
                return
            } else {
                handledInitialWaveID = waveID
                clearInitialWave(attemptID: capturedID)
                return
            }
        }
        let result = await library.refresh()
        guard isCurrent(capturedID) else { return }
        let pending = attempt?.id == capturedID && attempt?.armed == true
        if pending {
            _ = await resumeReadiness(result: result, attemptID: capturedID, completedBy: waveID)
        } else if result == .success {
            await prewarm(library.books.map(\.id))
        }
    }

    func snapshotReadinessChanged(_ readiness: LibraryViewModel.LoadReadiness) async {
        guard readiness == .success(identity), let capturedID = activeAttemptID,
              isCurrent(capturedID) else { return }
        if attempt?.id == capturedID, attempt?.armed == true {
            _ = await resumeReadiness(result: .success, attemptID: capturedID, completedBy: nil)
        }
        guard isCurrent(capturedID), trialReadinessRequested else { return }
        _ = await requestTrialReadiness()
    }

    /// A dismissal may need a current snapshot before opening its queued picker.
    /// The returned value admits that synchronous view presentation step only;
    /// the trial intent remains queued while picker/import facts block it.
    @discardableResult
    func requestTrialReadiness() async -> Bool {
        guard let capturedID = activeAttemptID, isCurrent(capturedID) else { return false }
        guard await revalidate(result: .success, attemptID: capturedID), isCurrent(capturedID) else { return false }
        trialReadinessRequested = true
        publishRequestedTrialIfReady()
        return true
    }

    private func isCurrent(_ attemptID: UUID) -> Bool {
        !retired && !Task.isCancelled && activeAttemptID == attemptID && currentIdentity() == identity
    }

    private func revalidate(result: LibraryViewModel.LoadResult, attemptID: UUID) async -> Bool {
        guard result == .success, isCurrent(attemptID) else { return false }
        if library.loadReadiness != .success(identity) {
            _ = await library.refresh()
        }
        return isCurrent(attemptID) && library.loadReadiness == .success(identity)
    }

    private func resumeReadiness(
        result: LibraryViewModel.LoadResult, attemptID: UUID, completedBy waveID: UUID?
    ) async -> Bool {
        guard isCurrent(attemptID), attempt?.id == attemptID, attempt?.armed == true,
              attempt?.recoveryClaimed == false else { return false }
        attempt?.recoveryClaimed = true
        var finished = false
        defer {
            if attempt?.id == attemptID {
                if finished { clearAttempt(attemptID: attemptID, completedBy: waveID) }
                else { attempt?.recoveryClaimed = false }
            }
        }
        guard await revalidate(result: result, attemptID: attemptID), isCurrent(attemptID) else { return false }
        await prewarm(library.books.map(\.id))
        guard isCurrent(attemptID), await revalidate(result: result, attemptID: attemptID),
              isCurrent(attemptID) else { return false }
        finished = finishReadiness(attemptID: attemptID, completedBy: waveID, alreadyClaimed: true)
        return finished
    }

    private func finishReadiness(
        attemptID: UUID, completedBy waveID: UUID?, alreadyClaimed: Bool = false
    ) -> Bool {
        guard isCurrent(attemptID), attempt?.id == attemptID, attempt?.armed == true,
              library.loadReadiness == .success(identity) else { return false }
        if !alreadyClaimed {
            guard attempt?.recoveryClaimed == false else { return completedInitialLoad }
            attempt?.recoveryClaimed = true
        }
        defer { if !alreadyClaimed { clearAttempt(attemptID: attemptID, completedBy: waveID) } }
        guard !completedInitialLoad else { return true }
        completedInitialLoad = true
        if facts.recoveryPending { publish(.recoveryPrompt, attemptID: attemptID, markSeen: suppressFirstBookPrompt) }
        else if !suppressFirstBookPrompt, !facts.hasSeenPrompt, library.books.isEmpty {
            publish(.firstBookPrompt, attemptID: attemptID)
        } else {
            trialReadinessRequested = true
            publishRequestedTrialIfReady(markSeen: !facts.hasSeenPrompt)
        }
        return true
    }

    private func publish(_ kind: Intent.Kind, attemptID: UUID, markSeen: Bool = false) {
        guard isCurrent(attemptID), library.loadReadiness == .success(identity) else { return }
        intent = Intent(identity: identity, attemptID: attemptID, kind: kind, markFirstBookPromptSeen: markSeen)
    }

    private func publishRequestedTrialIfReady(markSeen: Bool = false) {
        trialPromptSeenRequested = trialPromptSeenRequested || markSeen
        guard trialReadinessRequested, completedInitialLoad,
              attempt == nil,
              !facts.documentPickerPresented, !facts.firstPromptImportActive,
              let capturedID = activeAttemptID, isCurrent(capturedID),
              library.loadReadiness == .success(identity), intent == nil else { return }
        publish(.trialReady, attemptID: capturedID, markSeen: trialPromptSeenRequested)
    }

    private func clearAttempt(attemptID: UUID, completedBy waveID: UUID?) {
        guard attempt?.id == attemptID else { return }
        if let originalWave = attempt?.waveID { handledInitialWaveID = originalWave }
        handledRecoveryWaveID = waveID
        attempt = nil
        publishRequestedTrialIfReady()
    }

    private func clearInitialWave(attemptID: UUID) {
        guard attempt?.id == attemptID else { return }
        attempt?.waveID = nil
        attempt?.snapshotRead = false
        attempt?.completionObserved = false
        attempt?.snapshotFailed = false
        attempt?.fallbackStarted = false
    }
}
