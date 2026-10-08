







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

private enum FirstBookReadinessError: Error { case unavailable }

private struct FirstBookTourOwnership: Equatable {
    let attemptID: UUID
    let identity: LibraryAccountIdentity
    let bookID: BookID
}

struct LibraryTabView: View {

    let dependencies: LibraryTabDependencies
    let user: User
    let model: SignedInViewModel
    let dataUseConsentGranted: Bool
    let onLibraryReadyForTrial: () -> Void

    @Environment(AppRouter.self) private var router
    @Environment(TrialIntroPresentationState.self) private var trialPresentationState
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
    private let recoveryStore = FirstBookRecoveryStore()

    private var firstBookPromptSeenKey: String {
        "rishi.library.firstBookPrompt.seen.\(user.id.uuidString)"
    }

    private func markFirstBookPromptSeen() {
        hasSeenFirstBookPrompt = true
        UserDefaults.standard.set(true, forKey: firstBookPromptSeenKey)
        updateStartupFacts()
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
                        await MainActor.run { dependencies.currentAccountIdentity() == identity }
                    }
                )
            },
            acquireLease: { book in
                try await dependencies.bookSourceRegistry.acquireReadableSource(for: book)
            },
            ensureReady: { _ in
                await vm.refresh()
                guard !Task.isCancelled else { throw FirstBookReadinessError.unavailable }
                let libraryReady = await MainActor.run {
                    dependencies.currentAccountIdentity() == identity
                        && vm.loadReadiness == .success(identity)
                }
                guard !Task.isCancelled, libraryReady else {
                    throw FirstBookReadinessError.unavailable
                }
            },
            isCurrentIdentity: { expected in
                !Task.isCancelled && dependencies.currentAccountIdentity() == expected
            },
            persistRecovery: { captured in
                publishRecovery(true, identity: captured, isCancelled: Task.isCancelled)
            },
            dismiss: {
                showFirstBookPrompt = false
            },
            markSeen: { captured in
                guard dependencies.currentAccountIdentity() == captured else { return }
                markFirstBookPromptSeen()
            },
            requestTour: { bookUserID, bookID in
                guard dependencies.currentAccountIdentity() == identity, bookUserID == identity.userID else { return }
                router.requestReaderTour(for: bookID, userID: bookUserID)
                if let attemptID = sampleCoordinator?.attemptID {
                    ownedTourRequest = FirstBookTourOwnership(
                        attemptID: attemptID,
                        identity: identity,
                        bookID: bookID
                    )
                }
            },
            openBook: { book in
                guard dependencies.currentAccountIdentity() == identity else { return false }
                return openBook(book)
            },
            hasOwnedReaderWindow: { readerIdentity in
                #if targetEnvironment(macCatalyst)
                return dependencies.currentAccountIdentity() == identity
                    && readerWindows.openWindows[ReaderWindowID(
                        userID: readerIdentity.userID,
                        bookID: readerIdentity.bookID
                    )] != nil
                #else
                return false
                #endif
            },
            clearTourRequest: { bookUserID, bookID in
                guard dependencies.currentAccountIdentity() == identity,
                      bookUserID == identity.userID,
                      ownedTourRequest?.identity == identity,
                      ownedTourRequest?.bookID == bookID else { return }
                router.clearReaderTourRequest()
                ownedTourRequest = nil
            },
            clearRecovery: { captured in
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
              dependencies.currentAccountIdentity() == dependencies.accountIdentity else { return }
        let attemptID = UUID()
        let identity = dependencies.accountIdentity
        publishRecovery(true, identity: identity)
        firstPromptImportNeedsReopen = false
        let adapter = FirstPromptImportAdapter(
            attemptID: attemptID,
            identity: identity,
            isCurrent: {
                dependencies.currentAccountIdentity() == identity
                    && firstPromptImportAdapter?.attemptID == attemptID
                    && firstPromptImportAdapter?.identity == identity
            },
            onLifecycle: { event in
                guard event.attemptID == attemptID,
                      event.identity == identity,
                      dependencies.currentAccountIdentity() == identity,
                      firstPromptImportAdapter?.attemptID == attemptID else { return }
                publishCurrentRecovery(identity: identity)
            },
            acceptCandidate: { book in
                await acceptFirstPromptImportCandidate(
                    book,
                    attemptID: attemptID,
                    identity: identity
                )
            },
            onAccepted: { bookID in
                guard dependencies.currentAccountIdentity() == identity,
                      firstPromptImportAdapter?.attemptID == attemptID else { return }
                vm.markImportReaderOpenRequested(bookID: bookID)
            },
            onTerminated: { accepted in
                guard firstPromptImportAdapter?.attemptID == attemptID,
                      firstPromptImportAdapter?.identity == identity else { return }
                let wasRetired = firstPromptImportAdapter?.wasRetired == true
                firstPromptImportAdapter = nil
                if promptImportDismissalAttemptID == attemptID {
                    promptImportDismissalAttemptID = nil
                }
                if accepted, !wasRetired, trialReadyAfterDocumentPicker {
                    trialReadyAfterDocumentPicker = false
                    requestDeferredLibraryReadyAction()
                }
                if !accepted, !wasRetired,
                   dependencies.currentAccountIdentity() == identity {
                    trialReadyAfterDocumentPicker = false
                    firstPromptImportNeedsReopen = true
                    reopenFirstBookPromptIfSafe()
                }
                publishCurrentRecovery(identity: identity)
            }
        )
        firstPromptImportAdapter = adapter
        promptImportDismissalAttemptID = attemptID
        presentDocumentPickerAfterPrompt = true
        startup.cancelTrialReadiness()
        showFirstBookPrompt = false
    }

    @MainActor
    private func acceptFirstPromptImportCandidate(
        _ book: Book,
        attemptID: UUID,
        identity: LibraryAccountIdentity
    ) async -> Bool {
#if DEBUG
        if RishiE2EConfiguration.isRealAuth, RishiE2EConfiguration.fixtureURL != nil {
            return false
        }
#endif
        guard book.userId == identity.userID,
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
              firstPromptImportAdapter?.attemptID == attemptID,
              firstPromptImportAdapter?.identity == identity,
              !Task.isCancelled else { return false }
        let tour = FirstBookTourOwnership(attemptID: attemptID, identity: identity, bookID: book.id)
        ownedTourRequest = tour
        router.requestReaderTour(for: book.id, userID: identity.userID)
        let existingWindow: Bool
        #if targetEnvironment(macCatalyst)
        existingWindow = readerWindows.openWindows[ReaderWindowID(userID: identity.userID, bookID: book.id)] != nil
        #else
        existingWindow = false
        #endif
        let accepted = await currentSampleCoordinator().acceptOwnedPersonalImportHandoff(book, lease: lease)
        guard dependencies.currentAccountIdentity() == identity,
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
        showFirstBookPrompt = true
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
            return "The saved sample cannot be verified for this account. Import your own book to continue."
        }
        return "The sample could not be prepared. You can try again or import your own book."
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
        let isUITest: Bool
        #if DEBUG
        isUITest = ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1"
        #else
        isUITest = false
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
                if isUITest {
                    guard !Task.isCancelled, dependencies.currentAccountIdentity() == identity else { return }
                    _ = await dependencies.sampleBookInstaller.installIfNeeded(ownerId: identity.userID)
                    guard !Task.isCancelled, dependencies.currentAccountIdentity() == identity else { return }
                    _ = await dependencies.sampleReaderInstaller.installIfNeeded(ownerId: identity.userID)
                }
                #endif
            },
            suppressFirstBookPrompt: isUITest
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
        if pending.kind == .trialReady {
            guard !showDocumentPicker, !showFirstBookPrompt,
                  firstPromptImportAdapter == nil, !firstPromptImportNeedsReopen else { return }
        }
        guard let accepted = startup.takeIntent(id: pending.id) else { return }
        if accepted.markFirstBookPromptSeen { markFirstBookPromptSeen() }
        switch accepted.kind {
        case .firstBookPrompt:
            showFirstBookPrompt = true
        case .recoveryPrompt:
            firstPromptImportNeedsReopen = true
            showFirstBookPrompt = true
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
        if firstPromptImportAdapter == nil {
            if let sampleCoordinator,
               sampleCoordinator.state == .choosing || sampleCoordinator.state == .failed {
                publishRecovery(true, identity: dependencies.accountIdentity)
            }
            requestDeferredLibraryReadyAction()
        } else if presentDocumentPickerAfterPrompt {
            requestDeferredLibraryReadyAction()
        }
    }

    private func handleFirstBookPromptDisappearance(_ coordinator: FirstBookSampleCoordinator) {
        if let dismissalAttemptID = promptImportDismissalAttemptID,
           firstPromptImportAdapter?.attemptID == dismissalAttemptID {
            return
        }
        Task { @MainActor in
            if case .ready = coordinator.state {
                await coordinator.completeDismissal()
            } else if coordinator.state == .choosing || coordinator.state == .failed {
                await coordinator.skip()
            }
        }
    }

    private func handleDocumentPickerPresentationChange(_ isPresented: Bool) {
        guard !isPresented else { return }
        if firstPromptImportNeedsReopen {
            reopenFirstBookPromptIfSafe()
            return
        }
        guard trialReadyAfterDocumentPicker else { return }
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
                publishRecovery(true, identity: dependencies.accountIdentity)
                Task {
                    if retryable { await coordinator.retry() }
                    else { await coordinator.selectSample() }
                }
            },
            onImport: { beginFirstPromptImport() },
            onSkip: {
                publishRecovery(true, identity: dependencies.accountIdentity)
                Task { @MainActor in
                    await coordinator.skip()
                    showFirstBookPrompt = false
                }
            },
            isSamplePreparing: coordinator.state == .installing,
            isSampleRetryable: retryable,
            sampleFailureMessage: sampleFailureMessage(for: coordinator),
            recoveryMessage: recoveryStore.hasRecovery(userID: user.id)
                ? "Your previous choice is saved. You can retry the sample or import a book when you’re ready."
                : nil,
            sampleUnavailable: coordinator.failureKind == .provenanceUnavailable
        )
        .onDisappear { handleFirstBookPromptDisappearance(coordinator) }
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
        libraryNavigation
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
            refreshPersistedRecovery()
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
        .onChange(of: vm.loadReadiness) { _, _ in
            trialPresentationState.update()
            refreshPersistedRecovery()
        }
        .onChange(of: trialPresentationState.currentIdentity) { oldIdentity, newIdentity in
            guard oldIdentity != newIdentity,
                  newIdentity != dependencies.accountIdentity else { return }
            startup.retire()
            if let ownedTourRequest { clearOwnedTour(ownedTourRequest) }
            sampleCoordinator?.updateIdentity(newIdentity)
            firstPromptImportAdapter?.retire()
            firstPromptImportAdapter = nil
        }
        .onChange(of: router.path.isEmpty) { _, _ in trialPresentationState.update(); reopenFirstBookPromptIfSafe() }
        .onChange(of: router.sharedReaderRoute) { _, _ in trialPresentationState.update(); reopenFirstBookPromptIfSafe() }
        .onChange(of: showFirstBookPrompt) { _, _ in trialPresentationState.update() }
        .onChange(of: showDocumentPicker) { _, _ in trialPresentationState.update() }
        .onChange(of: showActiveReadingSessions) { _, _ in trialPresentationState.update(); reopenFirstBookPromptIfSafe() }
        .onChange(of: showConversations) { _, _ in trialPresentationState.update(); reopenFirstBookPromptIfSafe() }
        .onChange(of: model.showSettings) { _, _ in trialPresentationState.update(); reopenFirstBookPromptIfSafe() }
        .onChange(of: model.paywallFeature) { _, _ in trialPresentationState.update(); reopenFirstBookPromptIfSafe() }
        .onChange(of: vm.importError?.id) { _, errorID in
            if errorID == nil { reopenFirstBookPromptIfSafe() }
        }
        .onChange(of: vm.deletionError) { _, error in
            if error == nil { reopenFirstBookPromptIfSafe() }
        }
        .sheet(isPresented: $showActiveReadingSessions) {
            if let active = try? ActiveReadingSessionsView(
                api: dependencies.sharedReadingAPI, bookService: dependencies.sessionBookService,
                userId: user.id, sessionRegistry: dependencies.sharedReadingSessionRegistry, router: router,
                credentialSnapshot: dependencies.credentialSnapshot, credentialAuthority: dependencies.credentialAuthority,
                accountIdentity: dependencies.accountIdentity, currentAccountIdentity: dependencies.currentAccountIdentity) {
                active
            } else { ContentUnavailableView("Account changed", systemImage: "person.crop.circle.badge.exclamationmark") }
        }

        .sheet(isPresented: $showFirstBookPrompt, onDismiss: handleFirstBookPromptDismissal) {
            firstBookPrompt
        }
        .onChange(of: showDocumentPicker) { _, isPresented in
            updateStartupFacts()
            handleDocumentPickerPresentationChange(isPresented)
        }
        .onChange(of: vm.loadReadiness) { _, readiness in
            handleLoadReadinessChange(readiness)
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
            refreshLibrary: { await vm.refresh() },
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
