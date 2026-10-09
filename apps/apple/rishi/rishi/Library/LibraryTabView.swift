







import SwiftUI
import StoreKit
import Combine
import Dispatch

struct LibraryTabDependencies {
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let readerDefaults: AppReaderDefaults
    let syncEngine: SyncEngine
    let sharePackageService: SharePackageService
    let bookSourceRegistry: BookSourceRegistry
    let bookImportLifecycle: BookImportLifecycle
    let bookMaterializationCoordinator: BookMaterializationCoordinator
    let bookImportRecovery: BookImportRecovery
    let bookImportEvents: BookImportEvents
    let currentAccountGeneration: @Sendable () async -> UInt64?
    let credentialAuthority: SessionCredentialAuthority
    let credentialSnapshot: CredentialSnapshot
    let accountIdentity: LibraryAccountIdentity
    let currentAccountIdentity: @MainActor () -> LibraryAccountIdentity?
    let sharedReadingAPI: SharedReadingAPI
    let sharedReadingSessionRegistry: SharedReadingSessionRegistry
    let sessionBookService: SessionBookService
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let voicePresenter: VoiceSessionPresenter
    let groupID: GroupId?
    let settings: SettingsContentDependencies
}

struct LibrarySyncCompletionRefreshObserver {
    private let refresh: () async -> Void

    init(refresh: @escaping () async -> Void) {
        self.refresh = refresh
    }

    func statusChanged(from wasRunning: Bool?, to status: SyncStatusSnapshot) async {
        guard wasRunning == true, !status.isRunning else { return }
        await refresh()
    }
}

@MainActor
struct FirstBookRecoveryStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(userID: UserID) -> String {
        "rishi.library.firstBookPrompt.recovery.\(userID.uuidString)"
    }

    func hasRecovery(userID: UserID) -> Bool {
        defaults.bool(forKey: Self.key(userID: userID))
    }

    @discardableResult
    func setRecovery(
        _ pending: Bool,
        identity: LibraryAccountIdentity,
        currentIdentity: LibraryAccountIdentity?,
        isCancelled: Bool = false
    ) -> Bool {
        guard !isCancelled, identity == currentIdentity else { return false }
        defaults.set(pending, forKey: Self.key(userID: identity.userID))
        return true
    }
}

enum FirstBookUITestFixturePolicy {
    static func usesGenericFixtures(environment: [String: String]) -> Bool {
        environment["RISHI_UITEST"] == "1" && environment["RISHI_UITEST_FIRST_BOOK_PROMPT"] != "1"
    }
}

enum FirstBookImportGuidancePolicy {
    static func isActive(
        promptVisible: Bool,
        pendingDismissalOrCompletion: Bool,
        pendingPresentation: Bool,
        recoveryReopen: Bool,
        samplePreparing: Bool,
        sampleReadyForHandoff: Bool,
        pickerQueuedOrVisible: Bool,
        ownedImportAwaitingAcceptance: Bool
    ) -> Bool {
        promptVisible
            || pendingDismissalOrCompletion
            || pendingPresentation
            || recoveryReopen
            || samplePreparing
            || sampleReadyForHandoff
            || pickerQueuedOrVisible
            || ownedImportAwaitingAcceptance
    }
}

enum FirstBookSampleFailurePresentation {
    static let retryableMessage = "We couldn’t prepare the sample. Try again or import your own book."
    static let provenanceMessage = "The saved sample cannot be verified for this account. Import your own book to continue."
}

private enum FirstBookReadinessError: Error { case unavailable }

private struct FirstBookTourOwnership: Equatable {
    let attemptID: UUID
    let identity: LibraryAccountIdentity
    let bookID: BookID
}

@MainActor
final class FirstBookPromptHostAdmission {
    enum PickerCloseAction: Equatable {
        case reopenRecovery
        case waitForOwnedTerminal
        case requestOrdinaryReadiness
    }

    enum NativeDismissalOutcome: Equatable {
        case completed
        case retryableFailure
        case importPresented
        case externalFile
        case ignored
    }

    let id: UUID
    let identity: LibraryAccountIdentity
    let hostToken: TrialRootLifetimeAuthority.Anchor
    private(set) var revoked = false
    var retirementObserverID: UUID?
    var coordinator: FirstBookSampleCoordinator?
    var adapter: FirstPromptImportAdapter?
    fileprivate var tourRequest: FirstBookTourOwnership?
    var activeReceipt: FirstBookPromptDismissalReceipt?
    var pendingReceipt: FirstBookPromptDismissalReceipt?
    var dismissalReceipt: FirstBookPromptDismissalReceipt?
    var pickerReceipt: FirstBookPromptDismissalReceipt?
    var lifecycleTask: Task<Void, Never>?
    private(set) var retiredCleanupComplete = false
    var presentationVisible = false
    var dismissalInFlight = false
    var completed = false

    init(id: UUID = UUID(), identity: LibraryAccountIdentity, hostToken: TrialRootLifetimeAuthority.Anchor) {
        self.id = id
        self.identity = identity
        self.hostToken = hostToken
    }

    func revoke() { revoked = true }

    func canPresent(state: TrialIntroPresentationState, currentIdentity: LibraryAccountIdentity?) -> Bool {
        !completed && !revoked && !presentationVisible && pendingReceipt == nil && !dismissalInFlight
            && isCurrent(state: state, currentIdentity: currentIdentity)
    }

    func beginPresentation(_ receipt: FirstBookPromptDismissalReceipt) -> Bool {
        guard !completed, !revoked, !presentationVisible, pendingReceipt == nil, !dismissalInFlight else { return false }
        pickerReceipt = nil
        activeReceipt = receipt
        presentationVisible = true
        return true
    }

    func captureNativeDismissal(_ receipt: FirstBookPromptDismissalReceipt) -> Bool {
        guard presentationVisible, activeReceipt === receipt, pendingReceipt == nil else { return false }
        presentationVisible = false
        pendingReceipt = receipt
        return true
    }

    func contentDidDisappear(_ receipt: FirstBookPromptDismissalReceipt) {
        // Sheet content lifetime is not the native dismissal boundary.
    }

    func claimNativeDismissal(_ receipt: FirstBookPromptDismissalReceipt) -> FirstBookPromptDismissalReceipt.Reason? {
        guard pendingReceipt === receipt, !dismissalInFlight,
              let reason = receipt.consumeForNativeDismissal() else { return nil }
        pendingReceipt = nil
        activeReceipt = nil
        dismissalReceipt = receipt
        dismissalInFlight = true
        return reason
    }

    func finishDismissal(_ receipt: FirstBookPromptDismissalReceipt, keepRecoverySession: Bool) {
        guard dismissalInFlight, dismissalReceipt === receipt, receipt.admission === self else { return }
        dismissalInFlight = false
        dismissalReceipt = nil
        if !keepRecoverySession { completed = true }
    }

    func owns(_ receipt: FirstBookPromptDismissalReceipt) -> Bool {
        !revoked && !completed && (activeReceipt === receipt || pendingReceipt === receipt
            || dismissalReceipt === receipt || pickerReceipt === receipt)
    }

    func pickerCloseAction(recoveryPending: Bool) -> PickerCloseAction {
        if recoveryPending { return .reopenRecovery }
        if pickerReceipt != nil || adapter != nil { return .waitForOwnedTerminal }
        return .requestOrdinaryReadiness
    }

    func performOwnedReadiness(
        for receipt: FirstBookPromptDismissalReceipt,
        isCurrent: @MainActor () -> Bool,
        requestReadiness: @MainActor () async -> Bool,
        publishReadiness: @MainActor () -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, owns(receipt), isCurrent() else { return false }
        guard await requestReadiness(), !Task.isCancelled, owns(receipt), isCurrent() else { return false }
        guard !Task.isCancelled, owns(receipt), isCurrent() else { return false }
        return publishReadiness()
    }

    func performExplicitSkip(
        _ receipt: FirstBookPromptDismissalReceipt,
        isCurrent: @MainActor () -> Bool,
        persistPending: @MainActor () -> Void,
        skip: @MainActor () async -> Void,
        dismiss: @MainActor (FirstBookPromptDismissalReceipt) -> Void
    ) async -> Bool {
        guard activeReceipt === receipt, owns(receipt), isCurrent() else { return false }
        receipt.reason = .explicitSkip
        persistPending()
        await skip()
        guard !Task.isCancelled, activeReceipt === receipt, owns(receipt), isCurrent() else { return false }
        dismiss(receipt)
        return true
    }

    func performNativeDismissal(
        _ receipt: FirstBookPromptDismissalReceipt,
        isCurrent: @MainActor () -> Bool,
        skip: @MainActor () async -> Void,
        completeSample: @MainActor () async -> Void,
        requestReady: @MainActor (FirstBookPromptDismissalReceipt) async -> Bool
    ) async -> NativeDismissalOutcome {
        guard let reason = claimNativeDismissal(receipt) else { return .ignored }
        guard !Task.isCancelled, isCurrent() else {
            finishDismissal(receipt, keepRecoverySession: false)
            return .ignored
        }
        switch reason {
        case .explicitSkip, .interactiveIntentional:
            if reason == .interactiveIntentional,
               receipt.coordinator.state == .choosing || receipt.coordinator.state == .failed {
                await skip()
            }
            guard !Task.isCancelled, owns(receipt), isCurrent() else { return .ignored }
            _ = await requestReady(receipt)
            guard !Task.isCancelled, owns(receipt), isCurrent() else { return .ignored }
            finishDismissal(receipt, keepRecoverySession: false)
            return .completed
        case let .sample(attemptID):
            guard receipt.coordinator.attemptID == attemptID,
                  case .ready = receipt.coordinator.state else {
                finishDismissal(receipt, keepRecoverySession: true)
                return .ignored
            }
            await completeSample()
            guard !Task.isCancelled, owns(receipt), isCurrent() else { return .ignored }
            if receipt.coordinator.state == .failed {
                finishDismissal(receipt, keepRecoverySession: true)
                return .retryableFailure
            }
            guard receipt.coordinator.state == .choosing else {
                finishDismissal(receipt, keepRecoverySession: true)
                return .ignored
            }
            _ = await requestReady(receipt)
            guard !Task.isCancelled, owns(receipt), isCurrent() else { return .ignored }
            finishDismissal(receipt, keepRecoverySession: false)
            return .completed
        case .import:
            pickerReceipt = receipt
            _ = await requestReady(receipt)
            guard !Task.isCancelled, owns(receipt), isCurrent() else { return .ignored }
            finishDismissal(receipt, keepRecoverySession: true)
            return .importPresented
        case .externalFile:
            finishDismissal(receipt, keepRecoverySession: false)
            return .externalFile
        }
    }

    func retireSynchronously() {
        revoke()
        lifecycleTask?.cancel()
        coordinator?.cancelPendingHostWork()
        adapter?.cancelInternalWorkForHostRetirement()
    }

    func cleanupRetiredOwner() {
        guard !retiredCleanupComplete else { return }
        coordinator?.hostDidDisappear()
        adapter?.publishHostRetirement()
        completed = true
        retiredCleanupComplete = true
        activeReceipt = nil
        pendingReceipt = nil
        dismissalReceipt = nil
        pickerReceipt = nil
        presentationVisible = false
        dismissalInFlight = false
    }

    func isCurrent(state: TrialIntroPresentationState, currentIdentity: LibraryAccountIdentity?) -> Bool {
        !completed && !revoked && currentIdentity == identity && state.isHostLifetimeCurrent(hostToken, identity: identity)
    }
}

@MainActor
final class FirstBookPromptDismissalReceipt {
    enum Reason: Equatable {
        case interactiveIntentional
        case explicitSkip
        case sample(UUID)
        case `import`(UUID)
        case externalFile
    }

    let id: UUID
    let identity: LibraryAccountIdentity
    let coordinator: FirstBookSampleCoordinator
    let admission: FirstBookPromptHostAdmission
    var reason: Reason = .interactiveIntentional
    private(set) var consumed = false

    init(id: UUID = UUID(), identity: LibraryAccountIdentity, coordinator: FirstBookSampleCoordinator,
         admission: FirstBookPromptHostAdmission) {
        self.id = id
        self.identity = identity
        self.coordinator = coordinator
        self.admission = admission
    }

    func consume() -> Bool {
        guard !consumed else { return false }
        consumed = true
        return true
    }

    func consumeForNativeDismissal() -> Reason? {
        guard consume() else { return nil }
        if reason == .interactiveIntentional,
           case .ready = coordinator.state,
           let attemptID = coordinator.attemptID {
            reason = .sample(attemptID)
        }
        return reason
    }
}

@MainActor
private final class IncomingPromptWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait(timeout: Duration) async -> Bool {
        if let result { return result }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resolve(false)
        }
        let value = await withCheckedContinuation { continuation in
            if let result { continuation.resume(returning: result) }
            else { self.continuation = continuation }
        }
        task.cancel()
        return value
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

struct LibraryTabView: View {

    let dependencies: LibraryTabDependencies
    let user: User
    let model: SignedInViewModel
    let dataUseConsentGranted: Bool
    let onLibraryReadyForTrial: () -> Void

    @Environment(AppRouter.self) private var router
    @Environment(TrialIntroPresentationState.self) private var trialPresentationState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(IncomingBookPresentationReadiness.self) private var incomingReadiness
    @Environment(IncomingBookFileCoordinator.self) private var incomingFiles
    #if targetEnvironment(macCatalyst)
        @Environment(ReaderWindowCoordinator.self) private var readerWindows
    #endif
    @State private var vm: LibraryViewModel
    @State private var startup: LibraryStartupModel
    @State private var hasSeenFirstBookPrompt = false
    @State private var showFirstBookPrompt = false
    @State private var showDocumentPicker = false
    @State private var presentDocumentPickerAfterPrompt = false
    @State private var trialReadyAfterDocumentPicker = false
    @State private var pendingSubscriptionConfirmation = false
    @State private var showSubscriptionConfirmation = false
    @State private var showActiveReadingSessions = false
    @State private var showConversations = false
    @State private var trialRegistration: TrialIntroPresentationState.Registration?
    @State private var sampleCoordinator: FirstBookSampleCoordinator?
    @State private var firstPromptImportAdapter: FirstPromptImportAdapter?
    @State private var promptImportDismissalAttemptID: UUID?
    @State private var firstPromptImportNeedsReopen = false
    @State private var ownedTourRequest: FirstBookTourOwnership?
    @State private var promptDismissalReceipt: FirstBookPromptDismissalReceipt?
    @State private var pendingNativeDismissalReceipt: FirstBookPromptDismissalReceipt?
    @State private var promptAdmission: FirstBookPromptHostAdmission?
    @State private var pendingPromptPresentation = false
    @State private var incomingReaderRoute: ReaderRoute?
    @State private var presentedPromptKind: LibraryStartupModel.Intent.Kind?
    @State private var incomingPromptSuspension: IncomingPromptSuspension?
    @State private var incomingPromptWaiter: IncomingPromptWaiter?
    @State private var incomingHostRegistered = false
    @State private var incomingHostRegistrationToken: UUID?
    @State private var incomingReadinessOwner: UUID?
    private let recoveryStore = FirstBookRecoveryStore()

    private struct IncomingPromptSuspension {
        let identity: LibraryAccountIdentity
        let attemptID: UUID
        let kind: LibraryStartupModel.Intent.Kind
    }

    private var firstBookPromptPresentation: Binding<Bool> {
        Binding(
            get: { showFirstBookPrompt },
            set: { isPresented in
                if !isPresented { captureNativeDismissalReceipt() }
                showFirstBookPrompt = isPresented
            }
        )
    }

    private var firstBookPromptSeenKey: String {
        "rishi.library.firstBookPrompt.seen.\(user.id.uuidString)"
    }

    private var firstBookGuidanceActive: Bool {
        let admission = promptAdmission
        let coordinator = admission?.coordinator ?? sampleCoordinator
        let sampleReadyForHandoff: Bool
        if case .ready? = coordinator?.state {
            sampleReadyForHandoff = true
        } else {
            sampleReadyForHandoff = false
        }
        let ownedImportAwaitingAcceptance = firstPromptImportAdapter?.identity == dependencies.accountIdentity
            && (admission?.pickerReceipt != nil || admission?.adapter === firstPromptImportAdapter || admission?.lifecycleTask != nil)
        return FirstBookImportGuidancePolicy.isActive(
            promptVisible: showFirstBookPrompt || admission?.presentationVisible == true,
            pendingDismissalOrCompletion: promptDismissalReceipt != nil
                || pendingNativeDismissalReceipt != nil
                || admission?.pendingReceipt != nil
                || admission?.dismissalReceipt != nil
                || admission?.dismissalInFlight == true,
            pendingPresentation: pendingPromptPresentation,
            recoveryReopen: firstPromptImportNeedsReopen,
            samplePreparing: coordinator?.state == .installing,
            sampleReadyForHandoff: sampleReadyForHandoff,
            pickerQueuedOrVisible: presentDocumentPickerAfterPrompt
                || trialReadyAfterDocumentPicker
                || showDocumentPicker,
            ownedImportAwaitingAcceptance: ownedImportAwaitingAcceptance
        )
    }

    private var shouldSuppressImportTip: Bool {
        let identity = dependencies.accountIdentity
        let recoveryPending = recoveryStore.hasRecovery(userID: identity.userID)
            || trialPresentationState.recoveryActiveIdentity == identity
        return OnboardingGuidancePolicy.suppressesImportTip(
            firstBookGuidanceActive: firstBookGuidanceActive,
            recoveryPending: recoveryPending
        )
    }

    private func markFirstBookPromptSeen() {
        hasSeenFirstBookPrompt = true
        UserDefaults.standard.set(true, forKey: firstBookPromptSeenKey)
        updateStartupFacts()
    }

    @MainActor
    private func presentFirstBookPrompt() {
        guard !showFirstBookPrompt, pendingNativeDismissalReceipt == nil else {
            pendingPromptPresentation = true
            reportIncomingTabReadiness()
            return
        }
        guard dependencies.currentAccountIdentity() == dependencies.accountIdentity else { return }
        guard let hostToken = trialPresentationState.currentHostLifetimeToken,
              trialPresentationState.isHostLifetimeCurrent(hostToken, identity: dependencies.accountIdentity) else {
            pendingPromptPresentation = true
            reportIncomingTabReadiness()
            return
        }
        let admission: FirstBookPromptHostAdmission
        if let existing = promptAdmission, existing.hostToken == hostToken {
            guard existing.canPresent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()) else {
                pendingPromptPresentation = true
                reportIncomingTabReadiness()
                return
            }
            admission = existing
        } else {
            admission = FirstBookPromptHostAdmission(identity: dependencies.accountIdentity, hostToken: hostToken)
            promptAdmission = admission
        }
        let coordinator: FirstBookSampleCoordinator
        if let owned = admission.coordinator {
            coordinator = owned
            sampleCoordinator = owned
        } else {
            coordinator = makeSampleCoordinator()
            admission.coordinator = coordinator
        }
        let receipt = FirstBookPromptDismissalReceipt(
            identity: dependencies.accountIdentity,
            coordinator: coordinator,
            admission: admission
        )
        if admission.retirementObserverID == nil {
            admission.retirementObserverID = trialPresentationState.observeHostRetirement(hostToken) {
                let retiredTour = admission.tourRequest
                admission.retireSynchronously()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        admission.cleanupRetiredOwner()
                        if self.ownedTourRequest == retiredTour, let ownership = retiredTour {
                            self.clearOwnedTour(ownership)
                        }
                        guard self.promptAdmission === admission else { return }
                        self.startup.retire()
                        self.trialReadyAfterDocumentPicker = false
                        self.presentDocumentPickerAfterPrompt = false
                        self.firstPromptImportNeedsReopen = false
                        self.pendingPromptPresentation = false
                        if self.firstPromptImportAdapter === admission.adapter { self.firstPromptImportAdapter = nil }
                        if self.sampleCoordinator === admission.coordinator { self.sampleCoordinator = nil }
                        if self.promptDismissalReceipt?.admission === admission { self.promptDismissalReceipt = nil }
                        if self.pendingNativeDismissalReceipt?.admission === admission { self.pendingNativeDismissalReceipt = nil }
                        self.promptAdmission = nil
                        self.reportIncomingTabReadiness()
                    }
                }
            }
        }
        guard admission.retirementObserverID != nil,
              admission.beginPresentation(receipt) else {
            pendingPromptPresentation = true
            reportIncomingTabReadiness()
            return
        }
        pendingPromptPresentation = false
        promptDismissalReceipt = receipt
        showFirstBookPrompt = true
        reportIncomingTabReadiness()
    }

    @MainActor
    private func captureNativeDismissalReceipt() {
        guard pendingNativeDismissalReceipt == nil,
              let receipt = promptDismissalReceipt else { return }
        guard receipt.admission.captureNativeDismissal(receipt) else { return }
        pendingNativeDismissalReceipt = receipt
    }

    @MainActor
    private func dismissFirstBookPrompt(_ receipt: FirstBookPromptDismissalReceipt) {
        guard promptDismissalReceipt === receipt,
              receipt.admission.captureNativeDismissal(receipt) else { return }
        pendingNativeDismissalReceipt = receipt
        showFirstBookPrompt = false
    }

    @MainActor
    private func publishRecovery(_ pending: Bool, identity: LibraryAccountIdentity, isCancelled: Bool = false) {
        guard recoveryStore.setRecovery(
            pending,
            identity: identity,
            currentIdentity: dependencies.currentAccountIdentity(),
            isCancelled: isCancelled
        ) else { return }
        if !pending { firstPromptImportNeedsReopen = false }
        publishCurrentRecovery(identity: identity)
    }

    @MainActor
    private func publishCurrentRecovery(identity: LibraryAccountIdentity) {
        guard dependencies.currentAccountIdentity() == identity else { return }
        let sampleIsActive = sampleCoordinator?.state == .installing
        let importIsActive = firstPromptImportAdapter?.identity == identity
        trialPresentationState.setRecoveryActive(
            recoveryStore.hasRecovery(userID: identity.userID) || sampleIsActive || importIsActive,
            identity: identity
        )
        trialPresentationState.update()
        updateStartupFacts()
    }

    @MainActor
    private func makeSampleCoordinator() -> FirstBookSampleCoordinator {
        let identity = dependencies.accountIdentity
        let admission = promptAdmission
        let admitted: @MainActor @Sendable (LibraryAccountIdentity) -> Bool = { expected in
            guard let admission, promptAdmission === admission else { return false }
            return admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity())
                && expected == admission.identity
        }
        let coordinator = FirstBookSampleCoordinator(
            identity: identity,
            platform: {
                #if targetEnvironment(macCatalyst)
                return .catalyst
                #else
                return .ios
                #endif
            }(),
            install: {
                try await dependencies.sampleBookInstaller.installOrFind(
                    ownerId: identity.userID,
                    accountGeneration: identity.generation,
                    isCurrentAccount: {
                        await MainActor.run { admitted(identity) }
                    }
                )
            },
            acquireLease: { book in
                guard await MainActor.run(body: { admitted(identity) }) else { throw CancellationError() }
                let lease = try await dependencies.bookSourceRegistry.acquireReadableSource(for: book)
                guard await MainActor.run(body: { admitted(identity) }) else { throw CancellationError() }
                return lease
            },
            ensureReady: { _ in
                guard await MainActor.run(body: { admitted(identity) }) else { throw CancellationError() }
                await vm.refresh()
                guard !Task.isCancelled else { throw FirstBookReadinessError.unavailable }
                let libraryReady = await MainActor.run {
                    admitted(identity)
                        && vm.loadReadiness == .success(identity)
                }
                guard !Task.isCancelled, libraryReady else {
                    throw FirstBookReadinessError.unavailable
                }
            },
            isCurrentIdentity: { expected in
                !Task.isCancelled && admitted(expected)
            },
            persistRecovery: { captured in
                guard admitted(captured), !Task.isCancelled else { return }
                publishRecovery(true, identity: captured, isCancelled: Task.isCancelled)
            },
            dismiss: {
                guard let admission, admitted(identity), promptAdmission === admission,
                      promptDismissalReceipt?.admission === admission else { return }
                let attemptID = sampleCoordinator?.attemptID ?? UUID()
                guard let receipt = promptDismissalReceipt,
                      receipt.admission === admission else { return }
                receipt.reason = .sample(attemptID)
                dismissFirstBookPrompt(receipt)
            },
            markSeen: { captured in
                guard admitted(captured) else { return }
                markFirstBookPromptSeen()
            },
            requestTour: { bookUserID, bookID in
                guard admitted(identity), bookUserID == identity.userID else { return }
                router.requestReaderTour(for: bookID, userID: bookUserID)
                if let attemptID = sampleCoordinator?.attemptID {
                    let ownership = FirstBookTourOwnership(
                        attemptID: attemptID,
                        identity: identity,
                        bookID: bookID
                    )
                    admission?.tourRequest = ownership
                    ownedTourRequest = ownership
                }
            },
            openBook: { book in
                guard admitted(identity) else { return false }
                return await openBook(book)
            },
            hasOwnedReaderWindow: { readerIdentity in
                #if targetEnvironment(macCatalyst)
                return admitted(identity)
                    && readerWindows.openWindows[ReaderWindowID(
                        userID: readerIdentity.userID,
                        bookID: readerIdentity.bookID
                    )] != nil
                #else
                return false
                #endif
            },
            clearTourRequest: { bookUserID, bookID in
                let attemptID = sampleCoordinator?.attemptID
                let ownership = admission?.tourRequest
                guard admitted(identity), let attemptID,
                      bookUserID == identity.userID,
                      let ownership,
                      ownership.attemptID == attemptID,
                      ownership.identity == identity,
                      ownership.bookID == bookID,
                      ownedTourRequest == ownership else { return }
                router.clearReaderTourRequest()
                ownedTourRequest = nil
                admission?.tourRequest = nil
            },
            clearRecovery: { captured in
                guard admitted(captured), !Task.isCancelled else { return }
                publishRecovery(false, identity: captured, isCancelled: Task.isCancelled)
            }
        )
        sampleCoordinator = coordinator
        return coordinator
    }

    @MainActor
    private func currentSampleCoordinator() -> FirstBookSampleCoordinator {
        sampleCoordinator ?? makeSampleCoordinator()
    }

    @MainActor
    private func beginFirstPromptImport() {
        guard firstPromptImportAdapter == nil,
              dependencies.currentAccountIdentity() == dependencies.accountIdentity,
              let admission = promptAdmission,
              admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()) else { return }
        let attemptID = UUID()
        let identity = dependencies.accountIdentity
        guard let receipt = promptDismissalReceipt, receipt.admission === admission else { return }
        receipt.reason = .import(attemptID)
        publishRecovery(true, identity: identity)
        firstPromptImportNeedsReopen = false
        let adapter = FirstPromptImportAdapter(
            attemptID: attemptID,
            identity: identity,
            isCurrent: {
                promptAdmission === admission
                    && admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity())
                    && firstPromptImportAdapter?.attemptID == attemptID
                    && firstPromptImportAdapter?.identity == identity
            },
            onLifecycle: { event in
                guard event.attemptID == attemptID,
                      event.identity == identity,
                      promptAdmission === admission,
                      admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()),
                      dependencies.currentAccountIdentity() == identity,
                      firstPromptImportAdapter?.attemptID == attemptID else { return }
                publishCurrentRecovery(identity: identity)
            },
            acceptCandidate: { book in
                await acceptFirstPromptImportCandidate(
                    book,
                    attemptID: attemptID,
                    identity: identity,
                    admission: admission
                )
            },
            onAccepted: { bookID in
                guard promptAdmission === admission,
                      admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()),
                      dependencies.currentAccountIdentity() == identity,
                      firstPromptImportAdapter?.attemptID == attemptID else { return }
                vm.markImportReaderOpenRequested(bookID: bookID)
            },
            onTerminated: { accepted in
                guard admission.adapter?.attemptID == attemptID,
                      admission.adapter?.identity == identity else { return }
                let wasRetired = admission.adapter?.wasRetired == true
                if firstPromptImportAdapter === admission.adapter { firstPromptImportAdapter = nil }
                admission.adapter = nil
                if promptImportDismissalAttemptID == attemptID {
                    promptImportDismissalAttemptID = nil
                }
                guard !wasRetired, promptAdmission === admission,
                      admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()),
                      let ownedReceipt = admission.pickerReceipt else { return }
                if accepted {
                    let task = Task { @MainActor in
                        defer { admission.lifecycleTask = nil }
                        if trialReadyAfterDocumentPicker {
                            trialReadyAfterDocumentPicker = false
                            _ = await requestDeferredLibraryReadyAction(for: ownedReceipt)
                        }
                        guard promptAdmission === admission,
                              admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()) else { return }
                        finishPromptAdmission(admission)
                    }
                    admission.lifecycleTask = task
                } else {
                    trialReadyAfterDocumentPicker = false
                    firstPromptImportNeedsReopen = true
                    reopenFirstBookPromptIfSafe()
                }
                publishCurrentRecovery(identity: identity)
            }
        )
        admission.adapter = adapter
        firstPromptImportAdapter = adapter
        promptImportDismissalAttemptID = attemptID
        presentDocumentPickerAfterPrompt = true
        startup.cancelTrialReadiness()
        dismissFirstBookPrompt(receipt)
    }

    @MainActor
    private func acceptFirstPromptImportCandidate(
        _ book: Book,
        attemptID: UUID,
        identity: LibraryAccountIdentity,
        admission: FirstBookPromptHostAdmission
    ) async -> Bool {
#if DEBUG
        if RishiE2EConfiguration.isRealAuth, RishiE2EConfiguration.fixtureURL != nil {
            return false
        }
#endif
        guard book.userId == identity.userID,
              promptAdmission === admission,
              admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()),
              dependencies.currentAccountIdentity() == identity,
              firstPromptImportAdapter?.attemptID == attemptID,
              firstPromptImportAdapter?.identity == identity,
              !Task.isCancelled else { return false }
        let lease: BookSourceLease
        do {
            lease = try await dependencies.bookSourceRegistry.acquireReadableSource(for: book)
        } catch {
            return false
        }
        defer { withExtendedLifetime(lease) {} }
        guard dependencies.currentAccountIdentity() == identity,
              promptAdmission === admission,
              admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()),
              firstPromptImportAdapter?.attemptID == attemptID,
              firstPromptImportAdapter?.identity == identity,
              !Task.isCancelled else { return false }
        let tour = FirstBookTourOwnership(attemptID: attemptID, identity: identity, bookID: book.id)
        admission.tourRequest = tour
        ownedTourRequest = tour
        router.requestReaderTour(for: book.id, userID: identity.userID)
        let existingWindow: Bool
        #if targetEnvironment(macCatalyst)
        existingWindow = readerWindows.openWindows[ReaderWindowID(userID: identity.userID, bookID: book.id)] != nil
        #else
        existingWindow = false
        #endif
        guard let coordinator = admission.coordinator else { return false }
        let accepted = await coordinator.acceptOwnedPersonalImportHandoff(book, lease: lease)
        guard dependencies.currentAccountIdentity() == identity,
              admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()),
              promptAdmission === admission,
              firstPromptImportAdapter?.attemptID == attemptID,
              firstPromptImportAdapter?.identity == identity,
              !Task.isCancelled else {
            clearOwnedTour(tour)
            return false
        }
        if !accepted || existingWindow {
            clearOwnedTour(tour)
        }
        return accepted
    }

    @MainActor
    private func clearOwnedTour(_ ownership: FirstBookTourOwnership) {
        guard ownedTourRequest == ownership else { return }
        router.clearReaderTourRequest()
        ownedTourRequest = nil
        if promptAdmission?.tourRequest == ownership { promptAdmission?.tourRequest = nil }
    }

    @MainActor
    private func reopenFirstBookPromptIfSafe() {
        let sampleHandoffIsActive: Bool
        if let sampleCoordinator, case .ready = sampleCoordinator.state {
            sampleHandoffIsActive = true
        } else {
            sampleHandoffIsActive = false
        }
        guard firstPromptImportNeedsReopen,
              !showFirstBookPrompt,
              pendingNativeDismissalReceipt == nil,
              firstPromptImportAdapter == nil,
              !presentDocumentPickerAfterPrompt,
              !trialReadyAfterDocumentPicker,
              dependencies.currentAccountIdentity() == dependencies.accountIdentity,
              sampleCoordinator?.state != .installing,
              !sampleHandoffIsActive,
              vm.loadReadiness == .success(dependencies.accountIdentity),
              router.path.isEmpty,
              router.sharedReaderRoute == nil,
              !showDocumentPicker,
              vm.importError == nil,
              vm.deletionError == nil,
              !showActiveReadingSessions,
              !showConversations,
              !model.showSettings,
              model.paywallFeature == nil,
              !showSubscriptionConfirmation,
              !pendingSubscriptionConfirmation,
              trialPresentationState.activeOwnedCoverClaimID == nil else { return }
        #if targetEnvironment(macCatalyst)
        guard !readerWindows.openWindows.keys.contains(where: { $0.userID == user.id }) else { return }
        #endif
        firstPromptImportNeedsReopen = false
        presentFirstBookPrompt()
    }

    @MainActor
    private func refreshPersistedRecovery() {
        let identity = dependencies.accountIdentity
        publishCurrentRecovery(identity: identity)
        let pending = recoveryStore.hasRecovery(userID: identity.userID)
        if !pending {
            firstPromptImportNeedsReopen = false
        } else if
           vm.loadReadiness == .success(identity) {
            firstPromptImportNeedsReopen = true
        }
        reopenFirstBookPromptIfSafe()
    }

    @MainActor
    private func sampleFailureMessage(for coordinator: FirstBookSampleCoordinator) -> String? {
        guard coordinator.state == .failed else { return nil }
        if coordinator.failureKind == .provenanceUnavailable {
            return FirstBookSampleFailurePresentation.provenanceMessage
        }
        return FirstBookSampleFailurePresentation.retryableMessage
    }

    init(
        dependencies: LibraryTabDependencies,
        user: User,
        model: SignedInViewModel,
        dataUseConsentGranted: Bool = false,
        onLibraryReadyForTrial: @escaping () -> Void = {},
    ) {
        self.dependencies = dependencies
        self.user = user
        self.model = model
        self.dataUseConsentGranted = dataUseConsentGranted
        self.onLibraryReadyForTrial = onLibraryReadyForTrial
        let library = LibraryViewModel.make(
            bookStore: dependencies.bookStore,
            userId: user.id,
            importCoordinator: dependencies.importCoordinator,
            positionStore: dependencies.positionStore,
            bookFileStorage: dependencies.bookFileStorage,
            bookSourceRegistry: dependencies.bookSourceRegistry,
            bookImportLifecycle: dependencies.bookImportLifecycle,
            bookMaterializationCoordinator: dependencies.bookMaterializationCoordinator,
            bookImportRecovery: dependencies.bookImportRecovery,
            bookImportEvents: dependencies.bookImportEvents,
            currentAccountGeneration: dependencies.currentAccountGeneration,
            accountIdentity: dependencies.accountIdentity,
            currentAccountIdentity: dependencies.currentAccountIdentity,
            onBookDeleted: { bookId in
                try await dependencies.syncEngine.markBookDeleted(bookId)
            },
            syncEngine: dependencies.syncEngine
        )
        _vm = State(initialValue: library)
        let identity = dependencies.accountIdentity
        let usesGenericFixtures: Bool
        #if DEBUG
        usesGenericFixtures = FirstBookUITestFixturePolicy.usesGenericFixtures(
            environment: ProcessInfo.processInfo.environment
        )
        #else
        usesGenericFixtures = false
        #endif
        _startup = State(initialValue: LibraryStartupModel(
            identity: identity,
            library: library,
            currentIdentity: dependencies.currentAccountIdentity,
            sync: { onWaveID in
                _ = await dependencies.syncEngine.runOnce(onWaveID: onWaveID)
            },
            prewarm: { bookIDs in
                await dependencies.sharePackageService.prewarm(bookIDs: bookIDs)
            },
            prepareInitialSnapshot: {
                #if DEBUG
                if usesGenericFixtures {
                    guard !Task.isCancelled, dependencies.currentAccountIdentity() == identity else { return }
                    _ = await dependencies.sampleBookInstaller.installIfNeeded(ownerId: identity.userID)
                    guard !Task.isCancelled, dependencies.currentAccountIdentity() == identity else { return }
                    _ = await dependencies.sampleReaderInstaller.installIfNeeded(ownerId: identity.userID)
                }
                #endif
            },
            suppressFirstBookPrompt: usesGenericFixtures
        ))
    }

    private var settingsHandler: (() -> Void) {

        return { model.requestSettings() }
    }

    private func updateStartupFacts() {
        startup.updateFirstBookFacts(.init(
            hasSeenPrompt: hasSeenFirstBookPrompt,
            recoveryPending: recoveryStore.hasRecovery(userID: dependencies.accountIdentity.userID),
            documentPickerPresented: showDocumentPicker,
            firstPromptImportActive: firstPromptImportAdapter?.identity == dependencies.accountIdentity
        ))
    }

    private func performInitialLibraryLoad() async {
        hasSeenFirstBookPrompt = UserDefaults.standard.bool(forKey: firstBookPromptSeenKey)
        publishCurrentRecovery(identity: dependencies.accountIdentity)
        updateStartupFacts()
        await startup.load(consentGranted: dataUseConsentGranted, autoSync: dependencies.readerDefaults.autoSync)
        applyStartupIntent()
    }

    private func applyStartupIntent() {
        guard let pending = startup.intent,
              dependencies.currentAccountIdentity() == pending.identity,
              startup.isCurrentAttempt(pending.attemptID) else { return }
        if pending.kind == .firstBookPrompt || pending.kind == .recoveryPrompt {
            guard !incomingFiles.hasPendingFile(for: pending.identity),
                  incomingFiles.presentationError == nil else { return }
        }
        if pending.kind == .trialReady {
            guard !showDocumentPicker, !showFirstBookPrompt,
                  firstPromptImportAdapter == nil, !firstPromptImportNeedsReopen else { return }
        }
        guard let accepted = startup.takeIntent(id: pending.id) else { return }
        if accepted.markFirstBookPromptSeen { markFirstBookPromptSeen() }
        switch accepted.kind {
        case .firstBookPrompt:
            presentedPromptKind = .firstBookPrompt
            presentFirstBookPrompt()
        case .recoveryPrompt:
            presentedPromptKind = .recoveryPrompt
            firstPromptImportNeedsReopen = true
            presentFirstBookPrompt()
            publishCurrentRecovery(identity: accepted.identity)
        case .trialReady:
            trialReadyAfterDocumentPicker = false
            onLibraryReadyForTrial()
        }
    }

    /// Readiness lives on the model; only the queued picker presentation stays here.
    private func requestDeferredLibraryReadyAction() {
        updateStartupFacts()
        guard let attemptID = startup.currentAttemptID,
              startup.isCurrentAttempt(attemptID) else { return }
        Task { @MainActor in
            guard await startup.requestTrialReadiness(),
                  startup.isCurrentAttempt(attemptID),
                  dependencies.currentAccountIdentity() == dependencies.accountIdentity else { return }
            guard !showDocumentPicker else { return }
            if presentDocumentPickerAfterPrompt {
                presentDocumentPickerAfterPrompt = false
                trialReadyAfterDocumentPicker = true
                showDocumentPicker = true
                updateStartupFacts()
            } else {
                applyStartupIntent()
            }
        }
    }

    @MainActor
    private func requestDeferredLibraryReadyAction(for receipt: FirstBookPromptDismissalReceipt) async -> Bool {
        let admission = receipt.admission
        func isCurrent() -> Bool {
            promptAdmission === admission
                && admission.owns(receipt)
                && admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity())
        }
        guard isCurrent(), let attemptID = startup.currentAttemptID,
              startup.isCurrentAttempt(attemptID) else { return false }
        updateStartupFacts()
        return await admission.performOwnedReadiness(
            for: receipt,
            isCurrent: { isCurrent() && startup.isCurrentAttempt(attemptID) },
            requestReadiness: { await startup.requestTrialReadiness() },
            publishReadiness: {
                guard !showDocumentPicker, isCurrent() else { return false }
                if presentDocumentPickerAfterPrompt {
                    presentDocumentPickerAfterPrompt = false
                    trialReadyAfterDocumentPicker = true
                    admission.pickerReceipt = receipt
                    showDocumentPicker = true
                    updateStartupFacts()
                } else {
                    applyStartupIntent()
                }
                return true
            }
        )
    }

    @MainActor
    @discardableResult
    private func openBook(_ book: Book) -> Bool {
        model.hint(book)
        // The reader exit callback and the library boundary both initiate
        // cleanup asynchronously. Serialize the next reader launch behind
        // that cleanup at voice-start time, while keeping book navigation
        // responsive.
        dependencies.voicePresenter.scheduleRegisteredReaderCleanup()
        #if targetEnvironment(macCatalyst)
            return readerWindows.open(book: book, user: user)
        #else
            router.path.append(ReaderRoute.route(for: book))
            return true
        #endif
    }

    @MainActor
    private func handleImported(_ outcomes: [ImportCoordinator.ImportOutcome]) -> Bool {
        let successes = outcomes.compactMap(\.book)
        if !successes.isEmpty {
            markFirstBookPromptSeen()
        }
        #if DEBUG
        // The native shared-reading owner test needs to remain on the library
        // after the host-provided import so it can open the visible sharing
        // composer. Normal imports retain their existing auto-open behavior.
        if RishiE2EConfiguration.isRealAuth, RishiE2EConfiguration.fixtureURL != nil {
            return false
        }
        #endif
        guard successes.count == 1, let book = successes.first
        else { return false }
        return openBook(book)
    }

    private func handleLoadReadinessChange(_ readiness: LibraryViewModel.LoadReadiness) {
        updateStartupFacts()
        Task { @MainActor in
            await startup.snapshotReadinessChanged(readiness)
            applyStartupIntent()
        }
    }

    private func handleFirstBookPromptDismissal() {
        guard let receipt = pendingNativeDismissalReceipt else { return }
        pendingNativeDismissalReceipt = nil
        if promptDismissalReceipt === receipt { promptDismissalReceipt = nil }
        let admission = receipt.admission
        let task = Task { @MainActor in
            defer { admission.lifecycleTask = nil }
            let outcome = await admission.performNativeDismissal(
                receipt,
                isCurrent: {
                    promptAdmission === admission
                        && admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity())
                },
                skip: {
                    if receipt.reason == .interactiveIntentional {
                        await receipt.coordinator.skip()
                    }
                },
                completeSample: { await receipt.coordinator.completeDismissal() },
                requestReady: { await requestDeferredLibraryReadyAction(for: $0) }
            )
            switch outcome {
            case .externalFile:
                finishPromptAdmission(admission)
                reportIncomingTabReadiness()
                incomingPromptWaiter?.resolve(true)
                incomingPromptWaiter = nil
            case .retryableFailure:
                firstPromptImportNeedsReopen = true
                reopenFirstBookPromptIfSafe()
            case .completed:
                finishPromptAdmission(admission)
            case .importPresented, .ignored:
                break
            }
        }
        admission.lifecycleTask = task
    }

    @MainActor
    private func prepareForIncomingClaim() async -> Bool {
        let identity = dependencies.accountIdentity
        guard dependencies.currentAccountIdentity() == identity,
              !showDocumentPicker, firstPromptImportAdapter?.identity != identity else { return false }
        guard sampleCoordinator?.state != .installing, ownedTourRequest == nil else { return false }
        guard showFirstBookPrompt else {
            return promptAdmission?.lifecycleTask == nil && promptAdmission?.dismissalInFlight != true
        }
        let kind = presentedPromptKind
            ?? (recoveryStore.hasRecovery(userID: identity.userID) ? .recoveryPrompt : .firstBookPrompt)
        guard let receipt = promptDismissalReceipt,
              let attemptID = startup.currentAttemptID,
              receipt.identity == identity,
              promptAdmission?.adapter == nil,
              promptAdmission?.lifecycleTask == nil,
              promptAdmission?.dismissalInFlight != true else { return false }
        incomingPromptSuspension = IncomingPromptSuspension(identity: identity, attemptID: attemptID, kind: kind)
        let waiter = IncomingPromptWaiter()
        incomingPromptWaiter = waiter
        receipt.reason = .externalFile
        dismissFirstBookPrompt(receipt)
        // The coordinator owns the ten-second claim timeout and reports its
        // retryable error. This later local timeout only releases a waiter if
        // that host was concurrently retired before its cancellation arrives.
        let dismissed = await waiter.wait(timeout: .seconds(12))
        guard dependencies.currentAccountIdentity() == identity else { return false }
        if !dismissed { incomingPromptWaiter = nil }
        return dismissed
    }

    @MainActor
    private func restoreIncomingPromptAfterFailureIfSettled() {
        guard incomingFiles.presentationError == nil,
              !incomingFiles.hasPendingFile(for: dependencies.accountIdentity),
              let suspension = incomingPromptSuspension,
              suspension.identity == dependencies.accountIdentity,
              startup.isCurrentAttempt(suspension.attemptID) else { return }
        if startup.restorePromptAfterIncomingFailure(
            identity: suspension.identity, attemptID: suspension.attemptID, kind: suspension.kind
        ) {
            incomingPromptSuspension = nil
        }
    }

    private func reportIncomingTabReadiness() {
        let identity = dependencies.accountIdentity
        var blockers = Set<IncomingBookPresentationReadiness.Blocker>()
        if vm.loadReadiness != .success(identity) { blockers.insert(.libraryLoad) }
        let activePromptWork = firstPromptImportAdapter?.identity == identity
            || promptAdmission?.adapter != nil
            || promptAdmission?.lifecycleTask != nil
            || promptAdmission?.dismissalInFlight == true
            || sampleCoordinator?.state == .installing
            || ownedTourRequest != nil
        if showFirstBookPrompt && !activePromptWork { blockers.insert(.idleFirstBookPrompt) }
        if pendingPromptPresentation || pendingNativeDismissalReceipt != nil || promptAdmission?.pendingReceipt != nil
            || promptAdmission?.dismissalReceipt != nil
            || promptAdmission?.dismissalInFlight == true { blockers.insert(.promptDismissal) }
        if activePromptWork { blockers.insert(.promptImport) }
        if showDocumentPicker || presentDocumentPickerAfterPrompt || trialReadyAfterDocumentPicker {
            blockers.insert(.picker)
        }
        if model.showSettings { blockers.insert(.settings) }
        if showConversations { blockers.insert(.conversations) }
        if model.paywallFeature != nil { blockers.insert(.paywall) }
        if showSubscriptionConfirmation || pendingSubscriptionConfirmation { blockers.insert(.subscriptionConfirmation) }
        if showActiveReadingSessions { blockers.insert(.readingSessions) }
        if router.sharedReaderRoute != nil { blockers.insert(.sharedReader) }
        if vm.importError != nil || vm.deletionError != nil { blockers.insert(.importError) }
        incomingReadiness.report(.libraryTab, identity: identity, blockers: blockers, owner: incomingReadinessOwner)
    }

    @MainActor
    private func finishIncomingBookImport(_ book: Book, identity: LibraryAccountIdentity, attemptID: UUID?) {
        guard dependencies.currentAccountIdentity() == identity,
              dependencies.accountIdentity == identity,
              identity.userID == user.id,
              book.userId == identity.userID,
              let attemptID,
              startup.isCurrentAttempt(attemptID) else { return }
        _ = startup.supersedeFirstBookIntent(identity: identity, attemptID: attemptID)
        pendingPromptPresentation = false
        firstPromptImportNeedsReopen = false
        presentDocumentPickerAfterPrompt = false
        trialReadyAfterDocumentPicker = false
        presentedPromptKind = nil
        publishRecovery(false, identity: identity)
        incomingPromptSuspension = nil
        markFirstBookPromptSeen()
    }

    @MainActor
    private func finishIncomingBookPresentation(_ book: Book) -> IncomingBookOpenResult {
        let identity = dependencies.accountIdentity
        guard dependencies.currentAccountIdentity() == identity, book.userId == identity.userID else { return .unavailable }
        model.hint(book)
        dependencies.voicePresenter.scheduleRegisteredReaderCleanup()
        #if targetEnvironment(macCatalyst)
        let windowID = ReaderWindowID(userID: user.id, bookID: book.id)
        if readerWindows.openWindows[windowID] != nil {
            readerWindows.focus(bookID: book.id, userID: user.id)
            return .focusedExisting
        }
        return readerWindows.open(book: book, user: user) ? .presented : .unavailable
        #else
        incomingReaderRoute = ReaderRoute.route(for: book)
        return .presented
        #endif
    }

    @MainActor
    private func finishPromptAdmission(_ admission: FirstBookPromptHostAdmission) {
        guard promptAdmission === admission else { return }
        let coordinator = admission.coordinator
        let adapter = admission.adapter
        if let id = admission.retirementObserverID { trialPresentationState.removeHostRetirementObserver(id) }
        admission.retirementObserverID = nil
        admission.completed = true
        admission.adapter = nil
        admission.coordinator = nil
        admission.tourRequest = nil
        if sampleCoordinator === coordinator { sampleCoordinator = nil }
        if firstPromptImportAdapter === adapter { firstPromptImportAdapter = nil }
        promptAdmission = nil
    }

    private func handleDocumentPickerPresentationChange(_ isPresented: Bool) {
        guard !isPresented else { return }
        let pickerCloseAction: FirstBookPromptHostAdmission.PickerCloseAction
        if let promptAdmission {
            pickerCloseAction = promptAdmission.pickerCloseAction(recoveryPending: firstPromptImportNeedsReopen)
        } else if firstPromptImportNeedsReopen {
            pickerCloseAction = .reopenRecovery
        } else if firstPromptImportAdapter != nil {
            pickerCloseAction = .waitForOwnedTerminal
        } else {
            pickerCloseAction = .requestOrdinaryReadiness
        }
        switch pickerCloseAction {
        case .reopenRecovery:
            reopenFirstBookPromptIfSafe()
            return
        case .waitForOwnedTerminal:
            return
        case .requestOrdinaryReadiness:
            break
        }
        guard trialReadyAfterDocumentPicker else { return }
        // Prompt picker readiness belongs to the exact accepted adapter terminal callback.
        requestDeferredLibraryReadyAction()
    }

    private var firstBookPrompt: some View {
        let coordinator = currentSampleCoordinator()
        let retryable: Bool
        if coordinator.state == .failed {
            retryable = coordinator.failureKind == .retryable
        } else {
            retryable = false
        }
        return SampleOrImportScreen(
            onUseSample: {
                guard let admission = promptAdmission,
                      admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()) else { return }
                publishRecovery(true, identity: dependencies.accountIdentity)
                let task = Task { @MainActor in
                    defer { admission.lifecycleTask = nil }
                    if retryable { await coordinator.retry() }
                    else { await coordinator.selectSample() }
                }
                admission.lifecycleTask = task
            },
            onImport: { beginFirstPromptImport() },
            onSkip: {
                guard let admission = promptAdmission,
                      admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity()),
                      let receipt = promptDismissalReceipt,
                      receipt.admission === admission,
                      admission.activeReceipt === receipt else { return }
                let task = Task { @MainActor in
                    defer { admission.lifecycleTask = nil }
                    _ = await admission.performExplicitSkip(
                        receipt,
                        isCurrent: {
                            promptAdmission === admission
                                && promptDismissalReceipt === receipt
                                && admission.isCurrent(state: trialPresentationState, currentIdentity: dependencies.currentAccountIdentity())
                        },
                        persistPending: { publishRecovery(true, identity: dependencies.accountIdentity) },
                        skip: { await coordinator.skip() },
                        dismiss: { exactReceipt in dismissFirstBookPrompt(exactReceipt) }
                    )
                }
                admission.lifecycleTask = task
            },
            isSamplePreparing: coordinator.state == .installing,
            isSampleRetryable: retryable,
            sampleFailureMessage: sampleFailureMessage(for: coordinator),
            recoveryMessage: recoveryStore.hasRecovery(userID: user.id)
                ? "Your previous choice is saved. You can retry the sample or import a book when you’re ready."
                : nil,
            sampleUnavailable: coordinator.failureKind == .provenanceUnavailable
        )
        .onDisappear {
            if let receipt = promptDismissalReceipt {
                receipt.admission.contentDidDisappear(receipt)
            }
        }
    }

    private var libraryNavigation: some View {
        let bindableRouter = Bindable(router)
        let sharedReaderBinding = Binding<SharedReadingReaderRoute?>(
            get: { router.sharedReaderRoute },
            set: { next in
                let previous = router.sharedReaderRoute
                if let next {
                    guard let presentation = router.sharedReaderPresentation(for: next, accountID: user.id) else { return }
                    router.presentSharedReader(presentation.context, for: user.id)
                } else if let previous {
                    router.closeSharedReader(id: previous.id, accountID: previous.accountID)
                }
            }
        )
        let libraryLoadTaskID = user.id.uuidString + "-" + String(dependencies.accountIdentity.generation) + "-" + String(dataUseConsentGranted)
#if targetEnvironment(macCatalyst)
        let closeReaderBeforeBookDeletion: (@MainActor (Book) async -> Void)? = { book in
            await readerWindows.closeBeforeBookDeletion(bookID: book.id, userID: book.userId)
        }
#else
        let closeReaderBeforeBookDeletion: (@MainActor (Book) async -> Void)? = nil
#endif
        return NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
          
                path: bindableRouter.path,
                importCoordinator: dependencies.importCoordinator,
                onOpenBook: { book in _ = openBook(book) },
                onShowSettings: settingsHandler,
                onImported: handleImported,
                firstPromptImportAdapter: firstPromptImportAdapter,
                suppressImportTip: shouldSuppressImportTip,
                documentPickerPresented: $showDocumentPicker,
                sharePackageService: dependencies.sharePackageService,
                sharedReadingAPI: dependencies.sharedReadingAPI,
                sharedReadingRepair: { bookId in
                    Log.event("sharing.book.repair.started", data: [
                        "book_id": bookId.uuidString,
                    ])
                    let succeeded = await dependencies.syncEngine.repairBook(bookId)
                    Log.event(
                        succeeded ? "sharing.book.repair.completed" : "sharing.book.repair.failed",
                        level: succeeded ? .info : .error,
                        data: [
                            "book_id": bookId.uuidString,
                        ]
                    )
                    return succeeded
                },
                closeReaderBeforeBookDeletion: closeReaderBeforeBookDeletion,
                accountIdentity: dependencies.accountIdentity,
                onShowChats: { showConversations = true }
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showActiveReadingSessions = true
                    } label: {
                        Label("Active reading", systemImage: "person.3.fill")
                    }
                    .accessibilityIdentifier("shared-reading-active-sessions")
                    .accessibilityHint("View and rejoin open shared reading sessions")
                }
            }
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderDestinationView(
                    route: route,
                    hint: model.hint(for: route.bookId),
                    onRequestPaywall: { name in
                        let paid = dependencies.entitlementSnapshotStore.resolvedSnapshot?.isPaidActive ?? false
                        model.requestPaywall(PaywallRequest(feature: name), serverPaidActive: paid)
                    }
                )
            }
            .navigationDestination(item: $incomingReaderRoute) { route in
                ReaderDestinationView(
                    route: route,
                    hint: model.hint(for: route.bookId),
                    onRequestPaywall: { name in
                        let paid = dependencies.entitlementSnapshotStore.resolvedSnapshot?.isPaidActive ?? false
                        model.requestPaywall(PaywallRequest(feature: name), serverPaidActive: paid)
                    }
                )
            }
            .navigationDestination(item: sharedReaderBinding) { sharedRoute in
                if let presentation = router.sharedReaderPresentation(for: sharedRoute, accountID: user.id) {
                    ReaderDestinationView(
                        route: sharedRoute.readerRoute,
                        hint: model.hint(for: sharedRoute.readerRoute.bookId),
                        onRequestPaywall: { name in
                            let paid = dependencies.entitlementSnapshotStore.resolvedSnapshot?.isPaidActive ?? false
                            model.requestPaywall(PaywallRequest(feature: name), serverPaidActive: paid)
                        },
                        sharedReadingContext: presentation.context
                    )
                } else {
                    ContentUnavailableView("Reading session unavailable", systemImage: "exclamationmark.triangle")
                        .onAppear { router.closeSharedReader(id: sharedRoute.id, accountID: sharedRoute.accountID) }
                }
            }
            .navigationDestination(for: ConversationsRoute.self) { _ in
                ConversationsListHost(
                    vm: ConversationsListViewModel.make(
                        conversationStore: dependencies.conversationStore,
                        messageStore: dependencies.messageStore
                    ),
                    userId: user.id,
                    onSelect: { convo in model.present(conversation: convo) }
                )
            }
            .navigationDestination(isPresented: $showConversations) {
                ConversationsListHost(
                    vm: ConversationsListViewModel.make(
                        conversationStore: dependencies.conversationStore,
                        messageStore: dependencies.messageStore
                    ),
                    userId: user.id,
                    onSelect: { convo in model.present(conversation: convo) }
                )
            }
            .task {
         
                for await result in Transaction.currentEntitlements {
                    guard case .verified(let transaction) = result else {
                        
                        continue
                    }
                    let _ = try? await VerifyEndPont(body: .init(transactionId: transaction.id))
                        .send(using: dependencies.settings.workerClient)
                    
                    
                    
                    
                }
            }
            
            .task(id: libraryLoadTaskID) {
                await performInitialLibraryLoad()
            }
            .onChange(of: dependencies.settings.syncStatus.lastCompletedWaveID) { _, completedWaveID in
                guard let completedWaveID else { return }
                Task { @MainActor in
                    await startup.syncCompleted(waveID: completedWaveID)
                    applyStartupIntent()
                }
            }
        }
    }

    var body: some View {
        let lifecycleContent = addingLibraryTabLifecycle(to: libraryNavigation)
        let stateObservedContent = addingLibraryTabStateObservers(to: lifecycleContent)
        let observedContent = addingLibraryReadinessObservers(to: stateObservedContent)
        let presentationContent = addingLibraryPromptPresentations(to: observedContent)
        return addingLibrarySubscriptionPresentations(to: presentationContent)
    }

    private func addingLibraryTabLifecycle<Content: View>(to content: Content) -> some View {
        content
            .overlay {
                if case .failure(let identity) = vm.loadReadiness,
                   identity == dependencies.accountIdentity,
                   vm.books.isEmpty {
                    ContentUnavailableView {
                        Label("Library unavailable", systemImage: "books.vertical")
                    } description: {
                        Text("Your library could not be loaded.")
                    } actions: {
                        Button("Retry") { Task { await performInitialLibraryLoad() } }
                    }
                }
            }
            .environment(vm)
            .onAppear {
                incomingReadinessOwner = incomingReadiness.claimOwnership(of: .libraryTab)
                refreshPersistedRecovery()
                reportIncomingTabReadiness()
                if !incomingHostRegistered {
                    let importCoordinator = dependencies.importCoordinator
                    incomingHostRegistrationToken = incomingFiles.registerScene(
                        id: incomingReadiness.sceneID,
                        identity: dependencies.accountIdentity,
                        readiness: incomingReadiness,
                        currentIdentity: { dependencies.currentAccountIdentity() },
                        prepareForClaim: { await prepareForIncomingClaim() },
                        importOwned: { url in
                            let outcomes = await importCoordinator.registerOwnedSourceReadableBooks([url], providerKind: .fileProvider)
                            return outcomes.first ?? ImportCoordinator.ImportOutcome(url: url, book: nil, error: "empty_import_result")
                        },
                        refresh: { await vm.refresh() },
                        open: { book in finishIncomingBookPresentation(book) },
                        importAttemptID: { startup.currentAttemptID },
                        didImportSuccessfully: { book, identity, attemptID in
                            finishIncomingBookImport(book, identity: identity, attemptID: attemptID)
                        }
                    )
                    if let token = incomingHostRegistrationToken {
                        incomingFiles.setSceneForeground(id: incomingReadiness.sceneID, isForeground: scenePhase == .active, registrationToken: token)
                    }
                    incomingHostRegistered = true
                }
                guard trialRegistration == nil else { return }
                trialRegistration = trialPresentationState.register(.library, identity: dependencies.accountIdentity) {
                    var safety = TrialChildSafety()
                    safety.signedIn = true
                    safety.consent = true
                    safety.conversation = true
                    safety.voice = true
                    safety.libraryReady = vm.loadReadiness == .success(dependencies.accountIdentity)
                    safety.libraryModal = router.path.isEmpty
                        && router.sharedReaderRoute == nil
                        && incomingReaderRoute == nil
                        && !incomingFiles.hasPendingFile(for: dependencies.accountIdentity)
                        && incomingFiles.presentationError == nil
                        && !showFirstBookPrompt
                        && !showDocumentPicker
                        && !showActiveReadingSessions
                        && !showConversations
                        && !model.showSettings
                        && model.paywallFeature == nil
                        && !showSubscriptionConfirmation
                        && !pendingSubscriptionConfirmation
                        && !presentDocumentPickerAfterPrompt
                        && !trialReadyAfterDocumentPicker
                    safety.firstBookFlowActive = showFirstBookPrompt
                        || presentDocumentPickerAfterPrompt
                        || trialReadyAfterDocumentPicker
                        || firstPromptImportAdapter?.identity == dependencies.accountIdentity
                        || recoveryStore.hasRecovery(userID: dependencies.accountIdentity.userID)
                        || trialPresentationState.recoveryActiveIdentity == dependencies.accountIdentity
                    return safety
                }
                trialPresentationState.update()
            }
            .onDisappear {
                if let token = incomingHostRegistrationToken {
                    incomingFiles.unregisterScene(id: incomingReadiness.sceneID, registrationToken: token)
                }
                incomingHostRegistrationToken = nil
                incomingHostRegistered = false
                incomingReaderRoute = nil
                incomingReadiness.withdraw(.libraryTab, owner: incomingReadinessOwner)
                incomingReadinessOwner = nil
                incomingPromptWaiter?.resolve(false)
                incomingPromptWaiter = nil
                let covered = trialPresentationState.activeOwnedCoverClaimID != nil
                if !covered, dependencies.currentAccountIdentity() != dependencies.accountIdentity {
                    startup.retire()
                    sampleCoordinator?.hostDidDisappear()
                    firstPromptImportAdapter?.retire()
                }
                guard let trialRegistration else { return }
                trialPresentationState.unregister(
                    trialRegistration,
                    deferredUnderCover: trialPresentationState.activeOwnedCoverClaimID
                )
                self.trialRegistration = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)) { _ in
                refreshPersistedRecovery()
            }
    }

    private func addingLibraryTabStateObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                guard let token = incomingHostRegistrationToken else { return }
                incomingFiles.setSceneForeground(
                    id: incomingReadiness.sceneID,
                    isForeground: phase == .active,
                    registrationToken: token
                )
            }
            .onChange(of: vm.loadReadiness) { _, _ in
                trialPresentationState.update()
                refreshPersistedRecovery()
                reportIncomingTabReadiness()
            }
            .onChange(of: trialPresentationState.currentIdentity) { oldIdentity, newIdentity in
                guard oldIdentity != newIdentity,
                      newIdentity != dependencies.accountIdentity else { return }
                startup.retire()
                incomingPromptWaiter?.resolve(false)
                incomingPromptWaiter = nil
                incomingPromptSuspension = nil
                incomingReaderRoute = nil
                if let ownedTourRequest { clearOwnedTour(ownedTourRequest) }
                sampleCoordinator?.updateIdentity(newIdentity)
                firstPromptImportAdapter?.retire()
                firstPromptImportAdapter = nil
            }
            .onChange(of: trialPresentationState.currentRevision) { _, _ in
                if pendingPromptPresentation { presentFirstBookPrompt() }
                reportIncomingTabReadiness()
            }
            .onChange(of: router.path.isEmpty) { _, _ in
                updateTrialPresentationAndReopenPrompt()
            }
            .onChange(of: router.sharedReaderRoute) { _, _ in
                updateTrialPresentationAndReopenPrompt()
            }
            .onChange(of: incomingReaderRoute) { _, _ in
                incomingReadiness.setIncomingReaderRoutePresented(incomingReaderRoute != nil, owner: incomingReadinessOwner)
                trialPresentationState.update()
            }
            .onChange(of: showFirstBookPrompt) { _, _ in
                trialPresentationState.update()
                reportIncomingTabReadiness()
            }
            .onChange(of: showDocumentPicker) { _, _ in
                trialPresentationState.update()
                reportIncomingTabReadiness()
            }
            .onChange(of: showActiveReadingSessions) { _, _ in
                updateTrialPresentationAndReopenPrompt()
            }
            .onChange(of: showConversations) { _, _ in
                updateTrialPresentationAndReopenPrompt()
            }
            .onChange(of: model.showSettings) { _, _ in
                updateTrialPresentationAndReopenPrompt()
            }
            .onChange(of: model.paywallFeature) { _, _ in
                updateTrialPresentationAndReopenPrompt()
            }
            .onChange(of: showSubscriptionConfirmation) { _, _ in reportIncomingTabReadiness() }
            .onChange(of: pendingSubscriptionConfirmation) { _, _ in reportIncomingTabReadiness() }
    }

    private func updateTrialPresentationAndReopenPrompt() {
        trialPresentationState.update()
        reopenFirstBookPromptIfSafe()
        reportIncomingTabReadiness()
    }

    private func addingLibraryReadinessObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: promptAdmission?.dismissalInFlight) { _, _ in reportIncomingTabReadiness() }
            .onChange(of: sampleCoordinator?.state) { _, _ in reportIncomingTabReadiness() }
            .onChange(of: ownedTourRequest) { _, _ in reportIncomingTabReadiness() }
            .onChange(of: presentDocumentPickerAfterPrompt) { _, _ in reportIncomingTabReadiness() }
            .onChange(of: trialReadyAfterDocumentPicker) { _, _ in reportIncomingTabReadiness() }
            .onChange(of: firstPromptImportAdapter?.attemptID) { _, _ in reportIncomingTabReadiness() }
            .onChange(of: vm.importError?.id) { _, errorID in
                if errorID == nil { reopenFirstBookPromptIfSafe() }
                reportIncomingTabReadiness()
            }
            .onChange(of: vm.deletionError) { _, error in
                if error == nil { reopenFirstBookPromptIfSafe() }
                reportIncomingTabReadiness()
            }
            .onChange(of: incomingFiles.revision) { _, _ in
                reportIncomingTabReadiness()
                applyStartupIntent()
                restoreIncomingPromptAfterFailureIfSettled()
            }
    }

    private func addingLibraryPromptPresentations<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $showActiveReadingSessions) {
                if let active = try? ActiveReadingSessionsView(
                    api: dependencies.sharedReadingAPI, bookService: dependencies.sessionBookService,
                    userId: user.id, sessionRegistry: dependencies.sharedReadingSessionRegistry, router: router,
                    credentialSnapshot: dependencies.credentialSnapshot, credentialAuthority: dependencies.credentialAuthority,
                    accountIdentity: dependencies.accountIdentity, currentAccountIdentity: dependencies.currentAccountIdentity) {
                    active
                } else { ContentUnavailableView("Account changed", systemImage: "person.crop.circle.badge.exclamationmark") }
            }
            .sheet(isPresented: firstBookPromptPresentation, onDismiss: handleFirstBookPromptDismissal) {
                firstBookPrompt
            }
            .onChange(of: showDocumentPicker) { _, isPresented in
                updateStartupFacts()
                handleDocumentPickerPresentationChange(isPresented)
            }
            .onChange(of: vm.loadReadiness) { _, readiness in
                handleLoadReadinessChange(readiness)
                reportIncomingTabReadiness()
            }
            .onChange(of: startup.intent?.id) { _, _ in applyStartupIntent() }
            .onChange(of: firstPromptImportAdapter?.attemptID) { _, _ in
                updateStartupFacts()
                applyStartupIntent()
            }
#if !targetEnvironment(macCatalyst)
            .sheet(isPresented: Bindable(model).showSettings) {
                SettingsSheet(
                    dependencies: dependencies.settings,
                    user: user
                )
            }
#endif
    }

    private func addingLibrarySubscriptionPresentations<Content: View>(to content: Content) -> some View {
        content
            .rishiSubscriptionPresentation(item: Bindable(model).paywallFeature, onDismiss: {
                // Best-effort: purchase/restore via SubscriptionStoreView may have
                // synced entitlements while the sheet was up.
                Task {
                    _ = await dependencies.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .foreground,
                        credentialContext: .normal(dependencies.credentialSnapshot.lease))
                    guard dependencies.credentialAuthority.isCurrent(dependencies.credentialSnapshot.lease), pendingSubscriptionConfirmation else { return }
                    await MainActor.run {
                        pendingSubscriptionConfirmation = false
                        showSubscriptionConfirmation = true
                    }
                }
            }) { _ in
                if dependencies.groupID != nil {
                    SubscriptionsView(
                        dependencies: SubscriptionDependencies(
                            groupID: dependencies.groupID,
                            entitlementRefreshCoordinator: dependencies.entitlementRefreshCoordinator,
                            restoreService: dependencies.settings.restoreService,
                            customerEntitlements: dependencies.settings.customerEntitlements, store: dependencies.settings.store
                        ), credentialAuthority: dependencies.credentialAuthority,
                        credentialSnapshot: dependencies.credentialSnapshot,
                        onPurchaseCompleted: {
                        pendingSubscriptionConfirmation = true
                        model.dismissPaywall()
                    })
                } else {
                    NavigationStack {
                        ContentUnavailableView(
                            "Plans unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Could not load subscription plans. Try again later.")
                        )
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { model.dismissPaywall() }
                            }
                        }
                    }
                }
            }
            .onChange(of: dependencies.entitlementSnapshotStore.resolution) { old, new in
                let oldPaid = old.resolvedSnapshot?.isPaidActive ?? false
                let newPaid = new.resolvedSnapshot?.isPaidActive ?? false
                // Dismiss only when crossing into paid-active (verified grant).
                // Do not dismiss when already paid (allowance upgrade / plan change).
                if model.paywallFeature != nil, newPaid, !oldPaid {
                    model.dismissPaywall()
                }
            }
            .onChange(of: model.paywallFeature) { old, new in
                guard old != nil, new == nil, pendingSubscriptionConfirmation else { return }
                pendingSubscriptionConfirmation = false
                showSubscriptionConfirmation = true
            }
            .alert("Subscription active", isPresented: $showSubscriptionConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Thank you for subscribing. Your plan is now active.")
            }
            .deepLinkHandling(
                model: model,
                currentUserID: user.id
            )
    }

}

@MainActor
private struct LibraryTabPreviewHost: View {
    private let user = User(
        id: LibraryRootPreviewFixtures.userId,
        email: "reader@example.com",
        name: "Preview Reader"
    )
    @State private var vm = LibraryRootPreviewFixtures.makeViewModel(
        books: LibraryRootPreviewFixtures.populated
    )

    var body: some View {
        NavigationStack {
            LibraryRootView(
                importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
                onOpenBook: { _ in },
                onShowSettings: {},
                documentPickerPresented: nil
            )
        }
        .environment(vm)
        .task { await vm.refresh() }
        .environment(TrialIntroPresentationState())
    }
}

#Preview("Library tab — populated") {
    LibraryTabPreviewHost()
}
