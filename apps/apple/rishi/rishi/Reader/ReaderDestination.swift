import SwiftUI
import Observation
import ReadiumShared
import PDFKit

struct ReaderDestinationDependencies {
    let scopedMutationStore: BookScopedMutationStore
    let positionStore: any PositionStore
    let sourceLease: BookSourceLease
    let chapterIndexPersistence: any ChapterIndexPersistence
    let epubUnpackedCache: EPUBUnpackedCache
    let bookSourceRegistry: BookSourceRegistry
    let readerDefaults: AppReaderDefaults
    let readerSettingsStore: any ReaderSettingsStore
    let highlightStore: any HighlightStore
    let bookmarkStore: any BookmarkStore
    let bookFileStorage: BookFileStorage
    let bookSearch: any BookSearch
    let indexingHook: any BookIndexingHook
    let syncEngine: SyncEngine
    let conversationLookup: ConversationLookup
    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let chatService: any ChatService
    let readerVoiceDirtyHook: any VoiceTranscriptDirtyHook
    let voiceChapterIndexCoordinatorFactory: RealtimeVoiceSession.ChapterIndexCoordinatorFactory
    let voiceChapterIndexContentVersionProvider: @Sendable (BookID) async -> String?
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let voicePresenter: VoiceSessionPresenter
    let ttsCoordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: any TTSPlaying
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController
    let ttsPresenceController: TTSPresenceController
    let ttsPrewarmer: TTSPrewarmer
    let playbackOwner: ReadAloudPlaybackOwner

    @MainActor
    static func make(services: BootstrappedServices, book: Book, sourceLease: BookSourceLease) throws -> Self {
        let positionStore: any PositionStore
        let readerSettingsStore: any ReaderSettingsStore
        let highlightStore: any HighlightStore
        let bookmarkStore: any BookmarkStore
        let conversationStore: any ConversationStore
        let messageStore: any MessageStore
        let conversationLookup: ConversationLookup
        let chatService: any ChatService
        let chapterIndexPersistence: any ChapterIndexPersistence
        let readerVoiceDirtyHook: any VoiceTranscriptDirtyHook
        let voiceChapterIndexCoordinatorFactory: RealtimeVoiceSession.ChapterIndexCoordinatorFactory
        let voiceChapterIndexContentVersionProvider: @Sendable (BookID) async -> String?

        switch sourceLease.access {
        case .account(let permit):
            let source = sourceLease.sourceAccessPermit
            let effects = sourceLease.effectAuthority
            positionStore = ScopedPositionStore(
                base: services.library.positionStore,
                mutations: services.library.scopedMutationStore,
                permit: permit,
                originatingSource: source,
                sourceEffects: effects
            )
            guard let settings = services.library.readerSettingsStore as? UserDefaultsReaderSettingsStore else {
                throw ReaderDestinationCompositionError.readerSettingsUnavailable
            }
            readerSettingsStore = ScopedReaderSettingsStore(
                base: settings,
                mutations: services.library.scopedMutationStore,
                permit: permit,
                originatingSource: source,
                sourceEffects: effects
            )
            highlightStore = ScopedHighlightStore(
                base: services.library.highlightStore,
                mutations: services.library.scopedMutationStore,
                permit: permit,
                originatingSource: source,
                sourceEffects: effects
            )
            bookmarkStore = ScopedBookmarkStore(
                base: services.library.bookmarkStore,
                mutations: services.library.scopedMutationStore,
                permit: permit,
                originatingSource: source,
                sourceEffects: effects
            )
            chapterIndexPersistence = ScopedChapterIndexPersistence(
                base: services.library.chapterIndexPersistence,
                mutations: services.library.scopedMutationStore,
                permit: permit,
                originatingSource: source,
                sourceEffects: effects
            )
            let chapterContentVersion = book.chapterIndexContentVersion ?? bookChapterVersion(book, lease: sourceLease)
            voiceChapterIndexContentVersionProvider = { [bookID = permit.bookID, chapterContentVersion] requestedBookID in
                requestedBookID == bookID ? chapterContentVersion : nil
            }
            voiceChapterIndexCoordinatorFactory = { [book, sourceLease, chapterIndexPersistence, chapterContentVersion, chapterSummarizer = services.library.chapterSummarizer, unpackedCache = services.library.epubUnpackedCache] requestedBookID, requestedVersion in
                guard requestedBookID == book.id, requestedVersion == chapterContentVersion else { return nil }
                return ChapterIndexCoordinator(
                    persistence: chapterIndexPersistence,
                    source: ReaderLeaseChapterSource(book: book, lease: sourceLease, unpackedCache: unpackedCache),
                    summarizer: chapterSummarizer
                )
            }
            let scopedConversations = try ScopedConversationStore(
                base: services.chat.conversationStore,
                mutations: services.library.scopedMutationStore,
                authority: .book(permit),
                originatingSource: source,
                sourceEffects: effects
            )
            let scopedMessages = try ScopedMessageStore(
                base: services.chat.messageStore,
                conversations: scopedConversations,
                mutations: services.library.scopedMutationStore,
                authority: .book(permit),
                originatingSource: source,
                sourceEffects: effects
            )
            let sourceScopedDirtyHook = ReaderSourceScopedChatDirtyHook(
                syncEngine: services.sync.engine,
                source: source,
                effects: effects
            )
            readerVoiceDirtyHook = sourceScopedDirtyHook
            let admittedConversations = ReaderSourceAdmittedConversationStore(
                base: scopedConversations,
                source: source,
                effects: effects,
                onCommitted: { [engine = services.sync.engine] id in await engine.markConversationDirty(id) }
            )
            let admittedMessages = ReaderSourceAdmittedMessageStore(
                base: scopedMessages,
                source: source,
                effects: effects,
                onCommitted: { [engine = services.sync.engine] id in await engine.markMessageDirty(id) }
            )
            conversationStore = admittedConversations
            messageStore = admittedMessages
            conversationLookup = ConversationLookup(store: admittedConversations)
            chatService = services.chat.service.scoped(
                conversationLookup: conversationLookup,
                messageStore: admittedMessages,
                dirtyHook: sourceScopedDirtyHook
            )
        case .localPreview:
            throw ReaderDestinationCompositionError.localPreviewMustUsePreviewReader
        }

        return Self(
            scopedMutationStore: services.library.scopedMutationStore,
            positionStore: positionStore,
            sourceLease: sourceLease,
            chapterIndexPersistence: chapterIndexPersistence,
            epubUnpackedCache: services.library.epubUnpackedCache,
            bookSourceRegistry: services.library.bookSourceRegistry,
            readerDefaults: services.settings.readerDefaults,
            readerSettingsStore: readerSettingsStore,
            highlightStore: highlightStore,
            bookmarkStore: bookmarkStore,
            bookFileStorage: services.library.bookFileStorage,
            bookSearch: services.library.bookSearch,
            indexingHook: services.library.indexingHook,
            syncEngine: services.sync.engine,
            conversationLookup: conversationLookup,
            conversationStore: conversationStore,
            messageStore: messageStore,
            chatService: chatService,
            readerVoiceDirtyHook: readerVoiceDirtyHook,
            voiceChapterIndexCoordinatorFactory: voiceChapterIndexCoordinatorFactory,
            voiceChapterIndexContentVersionProvider: voiceChapterIndexContentVersionProvider,
            entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
            entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
            voicePresenter: services.voice.presenter,
            ttsCoordinator: services.audio.coordinator,
            ttsState: services.audio.ttsState,
            ttsEngine: services.audio.ttsEngine,
            ttsSettingsStore: services.audio.ttsSettingsStore,
            nowPlayingController: services.audio.nowPlayingController,
            ttsPresenceController: services.audio.ttsPresenceController,
            ttsPrewarmer: services.audio.ttsPrewarmer,
            playbackOwner: services.audio.playbackOwner
        )
    }
}

private enum ReaderDestinationCompositionError: Error {
    case readerSettingsUnavailable
    case localPreviewMustUsePreviewReader
}

struct ReaderSourceScopedChatDirtyHook: ChatDirtyHook, VoiceTranscriptDirtyHook, Sendable {
    let syncEngine: SyncEngine
    let source: BookSourceAccessPermit
    let effects: any BookSourceEffectAdmitting

    func conversationDidUpdate(_ id: ConversationID) async {
        guard let admission = try? effects.admit(source) else { return }
        defer { admission.release() }
        await syncEngine.markConversationDirty(id)
    }

    func messageDidUpdate(_ id: MessageID) async {
        guard let admission = try? effects.admit(source) else { return }
        defer { admission.release() }
        await syncEngine.markMessageDirty(id)
    }
}

/// Holds the source admission from before the database commit through the
/// corresponding sync dirty mark. The chat service's later dirty-hook call is
/// retained as an idempotent fallback for non-reader callers.
struct ReaderSourceAdmittedMessageStore: MessageStore, Sendable {
    private let base: any MessageStore
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting
    private let onCommitted: @Sendable (MessageID) async -> Void

    init(
        base: any MessageStore,
        source: BookSourceAccessPermit,
        effects: any BookSourceEffectAdmitting,
        onCommitted: @escaping @Sendable (MessageID) async -> Void
    ) {
        self.base = base
        self.source = source
        self.effects = effects
        self.onCommitted = onCommitted
    }

    func messages(for conversationId: ConversationID) async throws -> [Message] { try await base.messages(for: conversationId) }
    func message(_ id: MessageID) async throws -> Message? { try await base.message(id) }

    func upsert(_ message: Message) async throws {
        let admission = try effects.admit(source)
        defer { admission.release() }
        try await base.upsert(message)
        await onCommitted(message.id)
    }

    func delete(_ id: MessageID) async throws {
        let admission = try effects.admit(source)
        defer { admission.release() }
        try await base.delete(id)
        await onCommitted(id)
    }
}

struct ReaderSourceAdmittedConversationStore: ConversationStore, Sendable {
    private let base: any ConversationStore
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting
    private let onCommitted: @Sendable (ConversationID) async -> Void

    init(
        base: any ConversationStore,
        source: BookSourceAccessPermit,
        effects: any BookSourceEffectAdmitting,
        onCommitted: @escaping @Sendable (ConversationID) async -> Void
    ) {
        self.base = base
        self.source = source
        self.effects = effects
        self.onCommitted = onCommitted
    }

    func conversations(for userId: UserID) async throws -> [Conversation] { try await base.conversations(for: userId) }
    func conversation(_ id: ConversationID) async throws -> Conversation? { try await base.conversation(id) }

    func upsert(_ conversation: Conversation) async throws {
        let admission = try effects.admit(source)
        defer { admission.release() }
        try await base.upsert(conversation)
        await onCommitted(conversation.id)
    }

    func delete(_ id: ConversationID) async throws {
        let admission = try effects.admit(source)
        defer { admission.release() }
        try await base.delete(id)
        await onCommitted(id)
    }
}

private func bookChapterVersion(_ book: Book, lease: BookSourceLease) -> String {
    switch lease.cachePolicy {
    case .managed(_, let version):
        "reader-managed-\(version.materializationRevision.uuidString)"
    case .transient:
        "reader-transient-\(book.id.uuidString)-\(lease.sourceAccessPermit.sourceInstanceID.uuidString)"
    }
}

private struct ReaderLeaseChapterSource: ChapterSource, Sendable {
    let book: Book
    let lease: BookSourceLease
    let unpackedCache: EPUBUnpackedCache

    func chapters() async -> ChapterSourceResult {
        guard let admission = try? lease.effectAuthority.admit(lease.sourceAccessPermit) else {
            return unavailable
        }
        defer { admission.release() }
        let result: ChapterSourceResult
        switch book.formatType {
        case .epub:
            do {
                let publication = try await PublicationLoader(
                    unpackedCache: unpackedCache,
                    cachePolicy: lease.cachePolicy
                ).open(fileURL: lease.url)
                result = await EPUBChapterSource.snapshot(from: publication)
            } catch {
                result = unavailable
            }
        case .pdf:
            if let document = PDFDocument(url: lease.url) {
                result = await PDFChapterSource.snapshot(from: document)
            } else {
                result = unavailable
            }
        case .mobi, .azw3:
            result = unavailable
        }
        guard let validation = try? lease.effectAuthority.admit(lease.sourceAccessPermit) else { return unavailable }
        validation.release()
        return result
    }

    private var unavailable: ChapterSourceResult {
        ChapterSourceResult(availability: .unavailable(diagnostics: ["Chapter source unavailable"]), records: [])
    }
}

@MainActor
@Observable
final class ReaderPaywallRequestHandoff {
    private var pendingRequest: String?

    func queue(_ request: String) {
        pendingRequest = request
    }

    func takeAfterPromptDismissal() -> String? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}












struct ReaderDestination: View {
    let dependencies: ReaderDestinationDependencies
    let userId: UserID
    let onRequestPaywall: (String) -> Void
    let startReaderTour: Bool
    let pdfViewMode: Binding<PDFViewModeSetting>?
    let readerWindowCloseHandle: ReaderWindowCloseHandle?
    let sharedReadingCoordinator: SharedReadingSessionCoordinator?
    let sharedReadingJoin: SharedReadingJoin?
    let sharedReadingPeerMesh: SharedReadingPeerMesh?
    let sharedReadingLocalUserID: String?
    let onCopyShareLink: (() -> Void)?
    let sharedReadingMoreMenuContent: AnyView?
    let onFirstContentReady: @MainActor () async -> Void
    let sourceLease: BookSourceLease
    let sourceInvalidationCleanup: ReaderSourceInvalidationCleanup
    private let importInstrumentation: BookImportInstrumentation

    @State private var readAloudStartTask: Task<Void, Never>?
    @State private var readAloudStartRequest = UUID()
    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    private let readAloudHost = UUID()
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
    @State private var pendingNarrationUpgradePrompt: AIFeatureBlockReason?
    @State private var pendingNarrationUpgradeSessionToken: UUID?
    @State private var paywallRequestHandoff = ReaderPaywallRequestHandoff()
    @State private var didScheduleReaderIndexBackfill = false
    @State private var sharedNavigationRequest: SharedReaderNavigationRequest?
    @State private var sharedNavigationResult: SharedReaderNavigationResult?
    @State private var sharedSequence: Int64 = 0
    @State private var sharedLastSentSequence: Int64 = 0
    @State private var sharedRemoteSequence: Int64 = -1
    @State private var sharedAuthorityRoomEpoch: Int = -1
    @State private var sharedAuthorityControllerGeneration: Int = -1
    @State private var sharedAuthorityConnectionGeneration: Int = -1
    @State private var sharedAuthoritySessionID: String?
    @State private var sharedIsFollowingController = false
    @State private var sharedControlsLocked = false
    @State private var sharedSignalingFailureShown = false
    @State private var sharedNavigationError: String?
    @State private var sharedFollowerPlaybackTask: Task<Void, Never>?
    @State private var sharedFollowerPlaybackGeneration = UUID()
    @State private var sharedStateReconciler = SharedReadingStateReconciler()
    @State private var sharedAcceptedProgress: SharedReadingProgress?
    @State private var sharedNavigationEffects: [UInt64: SharedReadingEffect] = [:]
    @State private var sharedNavigationRevision: UInt64 = 0
    @State private var sharedRateScopeID = UUID()
    @State private var sharedRateRevision: UInt64 = 0
    @State private var sharedRateSessionID: String?
    @State private var sharedRateBookID: String?
    @State private var sharedRateContentHash: String?
    @State private var sharedRateUserID: String?
    @State private var sharedRateReaderBookID: String?
    @State private var sharedRateScopeConfigured = false
    @State private var sharedPromotionState: SharedReadingControllerPromotionState?
    @State private var sharedNeedsPromotionSnapshot = false
    @State private var sharedIsPromotedController = false
    @State private var sharedMicrophonePolicy = SharedReadingMicrophonePolicyState()
    @State private var sharedTTSIsPlaying = false

    @State private var voiceEntry: ReaderVoiceEntry
    @State private var readerTour: ReaderOnboardingTourCoordinator?
    @State private var showVoiceTextChat = false
    @State private var voiceTextVM: ChatPanelViewModel?
    /// Keep the EPUB viewport stable before playback starts. This is the
    /// compact player's reserved maximum, including its card and controls.
    private static let playerReservationHeight: CGFloat = 96

    init(
        vm: ReaderViewModel,
        dependencies: ReaderDestinationDependencies,
        sourceLease: BookSourceLease,
        sourceInvalidationCleanup: ReaderSourceInvalidationCleanup,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void,
        startReaderTour: Bool = false,
        pdfViewMode: Binding<PDFViewModeSetting>? = nil,
        readerWindowCloseHandle: ReaderWindowCloseHandle? = nil,
        sharedReadingCoordinator: SharedReadingSessionCoordinator? = nil,
        sharedReadingJoin: SharedReadingJoin? = nil,
        sharedReadingPeerMesh: SharedReadingPeerMesh? = nil,
        sharedReadingLocalUserID: String? = nil,
        onCopyShareLink: (() -> Void)? = nil,
        sharedReadingMoreMenuContent: AnyView? = nil,
        onFirstContentReady: @escaping @MainActor () async -> Void = {},
        importInstrumentation: BookImportInstrumentation = .shared
    ) {
        let peeked = dependencies.readerSettingsStore.peekPersistedTheme(for: vm.book.id)
        let initial = peeked ?? dependencies.readerDefaults.theme
        vm.theme = initial

        self._vm = State(initialValue: vm)
        self.dependencies = dependencies
        self.sourceLease = sourceLease
        self.sourceInvalidationCleanup = sourceInvalidationCleanup
        self.importInstrumentation = importInstrumentation
        let readerCacheState: BookImportMeasurement.CacheState
        let readableBytes: Int64?
        switch sourceLease.cachePolicy {
        case .managed(_, let version):
            readerCacheState = .hit
            readableBytes = version.byteCount
        case .transient:
            readerCacheState = .miss
            readableBytes = nil
        }
        importInstrumentation.recordRequestedReaderOpen(
            .readerSourceAcquired,
            bookID: vm.book.id,
            readableByteCount: readableBytes,
            cacheState: readerCacheState
        )
        importInstrumentation.recordRequestedReaderOpen(
            .readerAttachmentStarted,
            bookID: vm.book.id,
            readableByteCount: readableBytes,
            cacheState: readerCacheState
        )
        self.userId = userId
        self.onRequestPaywall = onRequestPaywall
        self.startReaderTour = startReaderTour
        self.pdfViewMode = pdfViewMode
        self.readerWindowCloseHandle = readerWindowCloseHandle
        self.sharedReadingCoordinator = sharedReadingCoordinator
        self.sharedReadingJoin = sharedReadingJoin
        self.sharedReadingPeerMesh = sharedReadingPeerMesh
        self.sharedReadingLocalUserID = sharedReadingLocalUserID
        self.onCopyShareLink = onCopyShareLink
        self.sharedReadingMoreMenuContent = sharedReadingMoreMenuContent
        self.onFirstContentReady = onFirstContentReady
        let tour = startReaderTour ? ReaderOnboardingTourCoordinator() : nil
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: dependencies.voicePresenter,
            conversationLookup: dependencies.conversationLookup,
            messageStore: dependencies.messageStore,
            dirtyHook: dependencies.readerVoiceDirtyHook,
            chapterIndexCoordinatorFactory: dependencies.voiceChapterIndexCoordinatorFactory,
            chapterIndexContentVersionProvider: dependencies.voiceChapterIndexContentVersionProvider,
            voiceLanguageProvider: { dependencies.readerDefaults.voiceLanguage },
            entitlementSnapshotStore: dependencies.entitlementSnapshotStore,
            entitlementRefreshCoordinator: dependencies.entitlementRefreshCoordinator,
            onRequestPaywall: onRequestPaywall,
            onVoiceStarted: { tour?.voiceChatStarted() }
        ))
        self._readerTour = State(initialValue: tour)
    }

    var body: some View {
        ReaderScreen(
            viewModel: vm,
            appDefaultTheme: dependencies.readerDefaults.theme,
            readerSettingsStore: dependencies.readerSettingsStore,
            highlightStore: dependencies.highlightStore,
            bookmarkStore: dependencies.bookmarkStore,


            bookmarkMarkDirty: { [dependencies, sourceLease] id in
                guard let admission = try? sourceLease.effectAuthority.admit(sourceLease.sourceAccessPermit) else { return }
                defer { admission.release() }
                await dependencies.syncEngine.markBookmarkDirty(id)
            },
            onReadAloud: {
                guard !sharedIsFollowingController && !sharedControlsLocked else { return }
                readerTour?.readAloudTapped()
                startReadAloud()
            },
            onReadAloudFrom: { locator in
                guard !sharedIsFollowingController && !sharedControlsLocked else { return }
                startReadAloud(from: locator)
            },
            onExplicitPageForward: {
                guard !sharedIsFollowingController && !sharedControlsLocked else { return nil }
                return readAloud?.beginExplicitPageForwardIntent()
            },
            onExplicitPageForwardCompleted: { id, didMove in
                readAloud?.completeExplicitForward(id: id, didMove: didMove)
            },
            onCopyShareLink: onCopyShareLink,
            sharedReadingMoreMenuContent: sharedReadingMoreMenuContent,
            onFirstContentReady: {
                await onFirstContentReady()
                await scheduleReaderIndexBackfillIfNeeded()
            },
            onLoadFailed: { await scheduleReaderIndexBackfillIfNeeded() },
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph,
            readAloudLocator: readAloud?.currentLocator,
            sharedNavigationRequest: sharedNavigationRequest,
            sharedReadingSessionID: sharedReadingJoin?.response.sessionId,
            isSharedFollower: sharedIsFollowingController || sharedControlsLocked,
            onSharedNavigationResult: { result in
                guard result.revision == sharedNavigationRevision,
                      let effect = sharedNavigationEffects[result.revision],
                      sharedStateReconciler.currentRevision == effect.revision else { return }
                sharedNavigationResult = result
                if case .accepted = result.outcome {
                    var reconciler = sharedStateReconciler
                    _ = reconciler.deferAcceptedNavigation(
                        effect,
                        observedPosition: sharedPosition(from: result.observedLocator)
                    )
                    sharedStateReconciler = reconciler
                } else if case let .failed(reason) = result.outcome {
                    sharedNavigationEffects.removeValue(forKey: result.revision)
                    var reconciler = sharedStateReconciler
                    _ = reconciler.complete(
                        effect,
                        succeeded: false,
                        observation: sharedLocalObservation()
                    )
                    sharedStateReconciler = reconciler
                    sharedNavigationError = reason
                    Log.sharedReading(.signalingEvent, level: .error, context: .init(
                        outcome: .rejected,
                        sessionID: effect.revision.authority.sessionId,
                        roomEpoch: effect.revision.authority.roomEpoch,
                        controllerGeneration: effect.revision.authority.controllerGeneration,
                        connectionGeneration: effect.revision.authority.connectionGeneration,
                        sequence: effect.revision.authority.progressSequence,
                        errorCode: "NAVIGATION_FAILED"
                    ))
                }
            },
            reservedPlayerHeight: reservedPlayerHeight,
            pdfViewMode: pdfViewMode?.wrappedValue ?? dependencies.readerDefaults.pdfViewMode,
            pdfViewModeBinding: pdfViewMode,
            keepChromeVisible: startReaderTour
        )


        .ttsErrorAlert(
            state: dependencies.ttsState,
            onRetry: { [weak readAloud] in
                guard let readAloud else { return }
                Task { @MainActor in await readAloud.repeatCurrent() }
            }
        )
        .task {
            // View-tree attachment is distinct from first visible PDF/EPUB
            // pixels; the latter is intentionally not implied by this mark.
            importInstrumentation.recordRequestedReaderOpen(
                .readerAttached,
                bookID: vm.book.id
            )
            sourceInvalidationCleanup.register {
                _ = await dependencies.playbackOwner.stop(reader: vm)
                await voiceEntry.endForReader()
            }
        }
        .task {
#if targetEnvironment(macCatalyst)
            if let readerWindowCloseHandle {
                let playbackOwner = dependencies.playbackOwner
                let voiceEntry = voiceEntry
                let host = readAloudHost
                let readAloud = readAloud
                readerWindowCloseHandle.register {
                    await playbackOwner.stop(host: host)
                    await readAloud?.clearSharedSessionRate()
                    await playbackOwner.setSharedSessionFollower(false, host: host)
                    await voiceEntry.endForReader()
                }
            }
#endif

            if startReaderTour {
                dependencies.voicePresenter.prewarmVoiceChat(for: vm.book.id, userID: userId)
            }

            // First-content is the preferred boundary for this non-critical
            // work. PDF navigators can legitimately finish their first page
            // without emitting a location callback, so keep a PDF-only
            // fallback. EPUB indexing is intentionally left on the
            // first-content boundary because extraction and embedding can be
            // expensive enough to compete with reader and voice startup.
            if vm.book.formatType == .pdf {
                await scheduleReaderIndexBackfillIfNeeded()
            }

            vm.onUserNavigation = { locator in
                guard !sharedIsFollowingController && !sharedControlsLocked else {
                    // A gesture which bypasses the reader chrome must not
                    // leave a follower on a different page indefinitely.
                    let previousNavigationRevision = sharedNavigationRevision
                    sharedNavigationRevision &+= 1
                    if let effect = sharedNavigationEffects.removeValue(forKey: previousNavigationRevision) {
                        sharedNavigationEffects[sharedNavigationRevision] = effect
                    }
                    if let position = sharedNavigationRequest?.position {
                        sharedNavigationRequest = SharedReaderNavigationRequest(
                            revision: sharedNavigationRevision,
                            position: position
                        )
                    }
                    return
                }
                guard let readAloud else { return }
                // Fence late Readium callbacks immediately. Resolving the
                // navigation intent can await paragraph extraction, and an
                // old `.playing` callback must not restore the old resume
                // candidate during that interval.
                readAloud.invalidateReadAloudPositionUpdates()
                Task { @MainActor in
                    readerTour?.userNavigated()
                    let snapshot = readAloud.beginUserNavigationIntent()
                    let destinationParagraphs = await vm.paragraphsForUserNavigationIntent(at: locator)
                    guard let intent = readAloud.resolveUserNavigationIntent(
                        snapshot: snapshot,
                        destinationParagraphs: destinationParagraphs,
                        destinationPage: locator.locations.page
                    ) else {
                        // Superseded by a newer swipe — do not stop; do not consume credit.
                        return
                    }
                    switch intent {
                    case .continuePlaying:
                        readAloud.allowReadAloudPositionUpdates()
                        return
                    case .stopPlaying:
                        vm.clearReadAloudResumeLocator()
                        readAloud.invalidateReadAloudPositionUpdates()
                        await readAloud.stop(preservingPosition: false)
                    }
                }
            }
            vm.onUserNavigationForTTSPagePrefetch = { [weak vm] locator in
                guard let readAloud, readAloud.canPrefetchPageEntry else { return }
                Task { @MainActor [weak vm, weak readAloud] in
                    guard let vm else { return }
                    guard let paragraph = await vm.firstParagraphForPageEntryPrefetch(at: locator) else { return }
                    await readAloud?.prefetchFirstParagraph(paragraph)
                }
            }
            vm.onExplicitPageForwardNavigation = { locator, id in
                guard !sharedIsFollowingController && !sharedControlsLocked,
                      let readAloud else { return }
                readerTour?.userNavigated()
                _ = readAloud.restartAtExplicitPage(locator, id: id)
            }
            syncBinding = ReaderPositionSyncBinding(
                viewModel: vm,
                syncEngine: dependencies.syncEngine,
                sourceLease: sourceLease
            )
        }
        .task(id: sharedReadingJoin?.response.sessionId) {
            await runSharedReadingIntegration()
        }
        .alert("Shared reading", isPresented: Binding(
            get: { sharedNavigationError != nil },
            set: { if !$0 { sharedNavigationError = nil } }
        )) {
            Button("OK") { sharedNavigationError = nil }
        } message: {
            Text(sharedNavigationError ?? "The shared position could not be opened.")
        }
        .onDisappear {
            didScheduleReaderIndexBackfill = false
            syncBinding = nil
            readAloudStartTask?.cancel()
            readAloudStartTask = nil
            readAloudStartRequest = UUID()
            sharedFollowerPlaybackTask?.cancel()
            sharedFollowerPlaybackTask = nil
            sharedFollowerPlaybackGeneration = UUID()
            sharedRateRevision &+= 1
            let sharedRateExitFence = SharedRateMutationFence(
                scopeID: sharedRateScopeID,
                revision: sharedRateRevision
            )

            Task { @MainActor [voiceEntry, voicePresenter = dependencies.voicePresenter, viewModel = vm] in
                voicePresenter.cancelPrewarm()
                if sharedReadingCoordinator != nil {
                    await dependencies.playbackOwner.stop(host: readAloudHost)
                    await readAloud?.clearSharedSessionRate(fence: sharedRateExitFence)
                }
#if !targetEnvironment(macCatalyst)
                await voiceEntry.endForReader()
#endif
                await viewModel.flush()
                if sharedReadingCoordinator != nil {
                    await dependencies.playbackOwner.setVolume(1)
                    dependencies.playbackOwner.setSharedSessionFollower(false, host: readAloudHost)
                }
                else {
#if !targetEnvironment(macCatalyst)
                    await dependencies.playbackOwner.release(host: readAloudHost)
#endif
                }
                readAloud = nil
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !dependencies.voicePresenter.isPresenting {
                IndexingIndicatorChip(
                    bookId: vm.book.id,
                    bookSearch: dependencies.bookSearch
                )
                .padding(.trailing, RishiSpacing.m)
                .padding(.bottom, RishiSpacing.s)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if sharedReadingCoordinator != nil, sharedReadingPeerMesh != nil {
                sharedReadingMicrophoneControls
                    .padding(.leading, RishiSpacing.m)
                    .padding(.bottom, RishiSpacing.s)
            }
        }
        .overlay(alignment: .bottom) {
            if sharedIsFollowingController {
                Text("Following the controller")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, RishiSpacing.s)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            let voiceActive = dependencies.voicePresenter.isPresenting
            let ttsVisible = readAloud?.showControls == true
            if !sharedIsFollowingController && !sharedControlsLocked && ReaderAudioChromeVisibility.shouldShow(
                voiceActive: voiceActive,
                ttsVisible: ttsVisible
            ) {
                ReaderAudioChromeOverlay(
                    isVisible: true,
                    mode: voiceActive ? .voice : .tts,
                    ttsState: dependencies.ttsState,
                    voiceState: dependencies.voicePresenter.state,
                    readAloud: readAloud,
                    onOpenVoiceChat: {
                        Task {
                            let controller = ensureReadAloudController()
                            await controller.pauseForVoiceHandoff()
                            voiceEntry.presentVoice(
                                bookId: vm.book.id,
                                context: vm.voiceContext(),
                                contextProvider: { await vm.liveVoiceContext() },
                                initialQuote: nil
                            )
                        }
                    },
                    onOpenReadAloud: {
                        Task {
                            await dependencies.voicePresenter.requestEnd()
                            guard !sharedIsFollowingController && !sharedControlsLocked else { return }
                            let controller = ensureReadAloudController()
                            if dependencies.playbackOwner.activeController === controller {
                                await controller.openReadAloudFromVoice(vm: vm)
                            } else {
                                _ = await dependencies.playbackOwner.start(
                                    controller: controller,
                                    reader: vm,
                                    host: readAloudHost
                                )
                            }
                        }
                    },
                    onEndVoice: {
                        Task {
                            await dependencies.voicePresenter.dismissVoiceChrome()
                            await readAloud?.resumeAfterVoiceIfNeeded()
                        }
                    },
                    onOpenTextChat: { showVoiceTextChat = true },
                )
            }
        }
        .overlay(alignment: .top) {
            if let readerTour {
                ReaderOnboardingTourOverlay(coordinator: readerTour)
                    .padding(.top, RishiSpacing.m)
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if sharedReadingCoordinator != nil {
                Text("Shared reading progress")
                    .accessibilityIdentifier("shared-reading-progress")
                    .accessibilityValue(sharedReadingProgressValue)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
        }
        #endif
        .sheet(isPresented: $showVoiceTextChat) {
            NavigationStack {
                if let voiceTextVM {
                    ChatPanelView(
                        viewModel: voiceTextVM,
                        initialQuote: dependencies.voicePresenter.pendingInitialQuote
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: dependencies.voicePresenter.currentBookId) {
                voiceTextVM = nil
                if let convo = try? await dependencies.conversationLookup.findOrCreate(
                    userId: userId,
                    bookId: dependencies.voicePresenter.currentBookId
                ) {
                    voiceTextVM = ChatPanelViewModel.make(
                        conversation: convo,
                        chatService: dependencies.chatService,
                        messageStore: dependencies.messageStore
                    )
                }
            }
        }
        .onChange(of: dependencies.voicePresenter.pendingInitialQuote) { _, quote in
            if quote != nil {
                showVoiceTextChat = true
            }
        }
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } }
        )) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(
                    initial: ra.pickerInitial,
                    userId: userId,
                    store: dependencies.ttsSettingsStore,
                    onDismiss: { settings in
                        ra.pickerInitial = settings
                        Task { await ra.applySettings(settings) }
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(
            item: $pendingNarrationUpgradePrompt,
            onDismiss: {
                if let token = pendingNarrationUpgradeSessionToken {
                    dependencies.ttsState.clearPreservedFailure(ifCurrent: token)
                }
                pendingNarrationUpgradeSessionToken = nil
                forwardPaywallRequestIfNeeded()
            }
        ) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    paywallRequestHandoff.queue("narration_exhausted")
                    pendingNarrationUpgradePrompt = nil
                },
                onDismiss: {
                    pendingNarrationUpgradePrompt = nil
                    if let token = pendingNarrationUpgradeSessionToken {
                        dependencies.ttsState.clearPreservedFailure(ifCurrent: token)
                    }
                    pendingNarrationUpgradeSessionToken = nil
                }
            )
        }
        .sheet(item: Binding(
            get: { voiceEntry.pendingUpgradePrompt },
            set: { newValue in if newValue == nil { voiceEntry.dismissUpgradePrompt() } }
        ), onDismiss: {
            forwardPaywallRequestIfNeeded()
        }) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    paywallRequestHandoff.queue("voice_chat_exhausted")
                    voiceEntry.dismissUpgradePrompt()
                },
                onDismiss: { voiceEntry.dismissUpgradePrompt() }
            )
        }
    }

    private var reservedPlayerHeight: CGFloat {
        vm.book.formatType == .epub ? Self.playerReservationHeight : 0
    }

    private var sharedReadingWireUserID: String {
        sharedReadingLocalUserID ?? userId.uuidString
    }

    @MainActor
    private func runSharedReadingIntegration() async {
        guard let sharedReadingCoordinator, let sharedReadingJoin else { return }
        // Admission/role is unknown until the authoritative room snapshot.
        dependencies.playbackOwner.setSharedSessionFollower(true, host: readAloudHost)
        var lastRemoteSequence: Int64 = -1
        var lastSentPosition: String?
        var lastSentPlaying: Bool?
        var lastSentRate: Double?
        var lastControllerSyncFailureKey: String?
        var loggedControllerSyncAuthority: String?
        let settings = await dependencies.ttsSettingsStore.load(userId: userId)
        while !Task.isCancelled {
            let snapshot = await sharedReadingCoordinator.snapshot()
            guard !Task.isCancelled else { break }
            let readerIdentityChanged = (sharedRateUserID != nil && sharedRateUserID != userId.uuidString)
                || (sharedRateReaderBookID != nil && sharedRateReaderBookID != String(describing: vm.book.id))
            if readerIdentityChanged {
                let oldScopeID = sharedRateScopeID
                sharedRateRevision &+= 1
                await readAloud?.clearSharedSessionRate(
                    fence: SharedRateMutationFence(scopeID: oldScopeID, revision: sharedRateRevision)
                )
                guard !Task.isCancelled else { break }
                sharedRateScopeID = UUID()
                sharedRateScopeConfigured = false
            }
            sharedRateUserID = userId.uuidString
            sharedRateReaderBookID = String(describing: vm.book.id)
            let authoritativeReady = snapshot.signalingFailure == nil
                && snapshot.hasAuthoritativeState
                && snapshot.hasAuthoritativeRoster
            let wasControlsLocked = sharedControlsLocked
            sharedControlsLocked = !authoritativeReady
            if !authoritativeReady && !wasControlsLocked {
                invalidateSharedFollowerWork(clearNavigation: true)
                lastRemoteSequence = -1
                sharedRemoteSequence = -1
            }
            if snapshot.signalingFailure != nil && !sharedSignalingFailureShown {
                sharedSignalingFailureShown = true
                sharedNavigationError = "The shared reading connection was lost. Rejoin the session to continue."
                readAloudStartTask?.cancel()
                readAloudStartRequest = UUID()
                await readAloud?.pause()
                guard !Task.isCancelled else { break }
            } else if authoritativeReady {
                sharedSignalingFailureShown = false
            }
            let roomEpoch = snapshot.roomEpoch.rawValue
            let controllerGeneration = snapshot.controllerGeneration.rawValue
            let connectionGeneration = snapshot.connectionGeneration.rawValue
            let syncFailureAuthority = "\(roomEpoch):\(controllerGeneration):\(connectionGeneration)"
            if loggedControllerSyncAuthority != syncFailureAuthority {
                loggedControllerSyncAuthority = syncFailureAuthority
                lastControllerSyncFailureKey = nil
            }
            if roomEpoch != sharedAuthorityRoomEpoch
                || controllerGeneration != sharedAuthorityControllerGeneration
                || snapshot.sessionId != sharedAuthoritySessionID {
                let wasFollowing = sharedIsFollowingController
                sharedAuthorityRoomEpoch = roomEpoch
                sharedAuthorityControllerGeneration = controllerGeneration
                sharedAuthoritySessionID = snapshot.sessionId
                lastRemoteSequence = -1
                sharedRemoteSequence = -1
                sharedAcceptedProgress = nil
                lastSentPosition = nil
                lastSentPlaying = nil
                lastSentRate = nil
                sharedFollowerPlaybackTask?.cancel()
                sharedFollowerPlaybackGeneration = UUID()
                sharedRateRevision &+= 1
                readAloud?.invalidateSharedFollowerEffects(
                    fence: SharedRateMutationFence(scopeID: sharedRateScopeID, revision: sharedRateRevision)
                )
                readAloudStartTask?.cancel()
                readAloudStartRequest = UUID()
                sharedNavigationEffects.removeAll()
                sharedStateReconciler = SharedReadingStateReconciler()
                let nextBookID = sharedReadingJoin.response.book.bookId
                let nextContentHash = sharedReadingJoin.response.book.contentHash
                let sharedRateScopeChanged = (sharedRateSessionID != nil && sharedRateSessionID != snapshot.sessionId)
                    || (sharedRateBookID != nil && sharedRateBookID != nextBookID)
                    || (sharedRateContentHash != nil && sharedRateContentHash != nextContentHash)
                if sharedRateScopeChanged {
                    let oldScopeID = sharedRateScopeID
                    sharedRateRevision &+= 1
                    await readAloud?.clearSharedSessionRate(
                        fence: SharedRateMutationFence(scopeID: oldScopeID, revision: sharedRateRevision)
                    )
                    guard !Task.isCancelled else { break }
                    sharedRateScopeID = UUID()
                    sharedRateScopeConfigured = false
                }
                sharedRateSessionID = snapshot.sessionId
                sharedRateBookID = nextBookID
                sharedRateContentHash = nextContentHash
                if wasFollowing,
                   snapshot.currentParticipantUserId == sharedReadingWireUserID,
                   snapshot.status == .active {
                    sharedIsPromotedController = true
                    sharedPromotionState = SharedReadingControllerPromotionPositionSelector.select(
                        isActivelySpeaking: readAloud?.isActivelySpeaking == true,
                        visiblePosition: sharedPosition(from: vm.visibleNavigatorLocator),
                        narrationPosition: sharedPosition(from: readAloud?.currentNarrationLocator),
                        effectiveRate: readAloud?.effectivePlaybackRate
                    )
                    sharedNeedsPromotionSnapshot = sharedPromotionState == nil
                } else if wasFollowing {
                    sharedIsPromotedController = false
                    readAloudStartTask?.cancel()
                    await readAloud?.pause()
                    guard !Task.isCancelled else { break }
                }
            }
            if connectionGeneration != sharedAuthorityConnectionGeneration {
                sharedAuthorityConnectionGeneration = connectionGeneration
                lastSentPosition = nil
                lastSentPlaying = nil
                lastSentRate = nil
            }
            let isFollower = authoritativeReady
                && snapshot.status == .active
                && snapshot.currentParticipantUserId != nil
                && snapshot.currentParticipantUserId != sharedReadingWireUserID
            let wasFollowingController = sharedIsFollowingController
            if wasFollowingController && !isFollower {
                invalidateSharedFollowerWork(clearNavigation: true)
            }
            dependencies.playbackOwner.setSharedSessionFollower(
                !authoritativeReady || isFollower,
                host: readAloudHost
            )
            let promotedToController = sharedIsFollowingController
                && authoritativeReady
                && snapshot.status == .active
                && snapshot.currentParticipantUserId == sharedReadingWireUserID
            if sharedIsFollowingController && !isFollower && !promotedToController
                && (snapshot.status == .ended || snapshot.sessionId != sharedReadingJoin.response.sessionId) {
                sharedRateRevision &+= 1
                await readAloud?.clearSharedSessionRate(
                    fence: SharedRateMutationFence(scopeID: sharedRateScopeID, revision: sharedRateRevision)
                )
                sharedAcceptedProgress = nil
                sharedRateScopeConfigured = false
            }
            sharedIsFollowingController = isFollower
            if isFollower {
                sharedIsPromotedController = false
                sharedPromotionState = nil
            } else if sharedIsPromotedController,
                      snapshot.status == .active,
                      snapshot.currentParticipantUserId == sharedReadingWireUserID {
                sharedPromotionState = SharedReadingControllerPromotionPositionSelector.select(
                    isActivelySpeaking: readAloud?.isActivelySpeaking == true,
                    visiblePosition: sharedPosition(from: vm.visibleNavigatorLocator),
                    narrationPosition: sharedPosition(from: readAloud?.currentNarrationLocator),
                    effectiveRate: readAloud?.effectivePlaybackRate
                )
                sharedNeedsPromotionSnapshot = sharedPromotionState == nil
            }
            let isTTSPlaying = readAloud?.isActivelySpeaking == true || dependencies.ttsState.status == .playing
            sharedTTSIsPlaying = isTTSPlaying
            await dependencies.playbackOwner.setVolume(
                SharedReadingAudioDucking.ttsVolume(
                    isTTSPlaying: isTTSPlaying,
                    speakerUserId: snapshot.speakerUserId
                )
            )
            guard !Task.isCancelled else { break }
            let floorGranted = authoritativeReady && snapshot.speakerUserId == sharedReadingWireUserID
            sharedMicrophonePolicy = SharedReadingMicrophonePolicy.setSpeakerFloorGranted(floorGranted, in: sharedMicrophonePolicy)
            if !isTTSPlaying, floorGranted {
                try? await sharedReadingCoordinator.releaseSpeaker()
                guard !Task.isCancelled else { break }
            }
            await sharedReadingPeerMesh?.setMicrophoneEnabled(
                sharedMicrophonePolicy.microphoneEnabled(isTTSPlaying: isTTSPlaying)
            )
            guard !Task.isCancelled,
                  snapshot.sessionId == sharedAuthoritySessionID,
                  roomEpoch == sharedAuthorityRoomEpoch,
                  controllerGeneration == sharedAuthorityControllerGeneration,
                  connectionGeneration == sharedAuthorityConnectionGeneration else {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            if isFollower,
               let progress = snapshot.latestProgress,
               progress.sequence > lastRemoteSequence,
               progress.sessionId == sharedReadingJoin.response.sessionId,
               progress.bookId == sharedReadingJoin.response.book.bookId,
               progress.contentHash == sharedReadingJoin.response.book.contentHash {
                lastRemoteSequence = progress.sequence
                sharedRemoteSequence = progress.sequence
                sharedAcceptedProgress = progress
                sharedRateRevision &+= 1
                readAloud?.invalidateSharedFollowerEffects(
                    fence: SharedRateMutationFence(scopeID: sharedRateScopeID, revision: sharedRateRevision)
                )
            }
            if isFollower, let progress = sharedAcceptedProgress,
               progress.sessionId == snapshot.sessionId,
               progress.bookId == sharedReadingJoin.response.book.bookId,
               progress.contentHash == sharedReadingJoin.response.book.contentHash {
                await reconcileSharedFollower(progress, snapshot: snapshot)
            }

            if authoritativeReady,
               snapshot.status == .active,
               snapshot.currentParticipantUserId == sharedReadingWireUserID,
               !sharedNeedsPromotionSnapshot,
               let position = sharedPromotionState.flatMap({ sharedEncodedPosition($0.position) })
                   ?? vm.latestLocator.flatMap { locator in
                       try? ReaderPositionLocator(locator: locator, source: vm.latestPositionSource).encodedJSONString()
                   } {
                let isPlaying = isTTSPlaying
                let rate = sharedPromotionState?.rate ?? readAloud?.pickerInitial.speed ?? settings.speed
                if position != lastSentPosition || isPlaying != lastSentPlaying || rate != lastSentRate {
                    sharedSequence &+= 1
                    let progress = SharedReadingProgress(
                        sessionId: sharedReadingJoin.response.sessionId,
                        bookId: sharedReadingJoin.response.book.bookId,
                        contentHash: sharedReadingJoin.response.book.contentHash,
                        format: sharedReadingJoin.response.book.format,
                        sequence: sharedSequence,
                        position: position,
                        isPlaying: isPlaying,
                        ttsRate: rate,
                        updatedAt: Date()
                    )
                    do {
                        try await sharedReadingCoordinator.sendControllerSyncFrame(progress)
                        sharedLastSentSequence = sharedSequence
                        lastSentPosition = position
                        lastSentPlaying = isPlaying
                        lastSentRate = rate
                        lastControllerSyncFailureKey = nil
                    } catch let error as SharedReadingError {
                        let failureKey = "\(syncFailureAuthority):\(error.code.rawValue):\(error.httpStatus ?? 0)"
                        if lastControllerSyncFailureKey != failureKey {
                            lastControllerSyncFailureKey = failureKey
                            Log.sharedReading(.signalingEvent, level: .error, context: .init(
                                outcome: .failed,
                                correlationID: error.correlationId,
                                sessionID: progress.sessionId,
                                statusCode: error.httpStatus,
                                roomEpoch: roomEpoch,
                                controllerGeneration: controllerGeneration,
                                connectionGeneration: connectionGeneration,
                                sequence: progress.sequence,
                                errorCode: "CONTROLLER_SYNC_\(error.code.rawValue)"
                            ))
                        }
                        if error.code == .sessionEnded || error.code == .removedFromSession {
                            await sharedReadingCoordinator.reportTerminalSyncSendFailure(error)
                        }
                    } catch {
                        let failureKey = "\(syncFailureAuthority):UNKNOWN"
                        if lastControllerSyncFailureKey != failureKey {
                            lastControllerSyncFailureKey = failureKey
                            Log.sharedReading(.signalingEvent, level: .error, context: .init(
                                outcome: .failed,
                                sessionID: progress.sessionId,
                                roomEpoch: roomEpoch,
                                controllerGeneration: controllerGeneration,
                                connectionGeneration: connectionGeneration,
                                sequence: progress.sequence,
                                errorCode: "CONTROLLER_SYNC_UNKNOWN"
                            ))
                        }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        sharedFollowerPlaybackTask?.cancel()
    }

    @MainActor
    private func reconcileSharedFollower(_ progress: SharedReadingProgress, snapshot: SharedReadingSessionCoordinatorSnapshot) async {
        guard let authoritySessionID = snapshot.sessionId,
              authoritySessionID == progress.sessionId else { return }
        let wrappedPosition = try? ReaderPositionLocator.decode(jsonString: progress.position)
        let targetLocator = wrappedPosition?.toReadiumLocator()
            ?? (try? Locator(jsonString: progress.position))
        guard let targetLocator, let desiredSharedPosition = sharedPosition(from: targetLocator) else {
            sharedNavigationError = "The controller's reading position is unavailable."
            return
        }
        let desiredPosition = SharedReadingDesiredPosition(
            position: desiredSharedPosition,
            source: wrappedPosition?.source == .readAloud ? .readAloud : .reader
        )
        let authority = SharedReadingAuthorityRevision(
            sessionId: progress.sessionId,
            roomEpoch: snapshot.roomEpoch.rawValue,
            controllerGeneration: snapshot.controllerGeneration.rawValue,
            connectionGeneration: snapshot.connectionGeneration.rawValue,
            progressSequence: progress.sequence,
            bookId: progress.bookId,
            contentHash: progress.contentHash
        )
        let observation = sharedLocalObservation()
        let input = SharedReadingReconcileInput(
            authority: authority,
            desiredPosition: desiredPosition,
            desiredPlayback: progress.isPlaying ? .playing : .paused,
            desiredRate: progress.ttsRate,
            visiblePosition: sharedPosition(from: vm.visibleNavigatorLocator),
            narrationPosition: sharedPosition(from: readAloud?.currentNarrationLocator),
            playback: sharedObservedPlayback,
            effectiveRate: readAloud?.effectivePlaybackRate,
            rateIsConfigured: sharedRateScopeConfigured,
            audioReady: vm.publication != nil,
            readerReady: vm.publication != nil
        )
        var reconciler = sharedStateReconciler
        let effects = reconciler.reconcile(input)
        if let (_, pendingNavigation) = sharedNavigationEffects.first,
           pendingNavigation.revision != reconciler.currentRevision {
            sharedNavigationEffects.removeAll()
        }

        if let navigation = effects.first(where: { if case .navigateVisible = $0 { true } else { false } }),
           case .navigateVisible = navigation {
            if sharedNavigationEffects.values.first != navigation
                || sharedNavigationRequest?.position != progress.position {
                sharedNavigationRevision &+= 1
                sharedNavigationRequest = SharedReaderNavigationRequest(
                    revision: sharedNavigationRevision,
                    position: progress.position
                )
                sharedNavigationEffects.removeAll()
                sharedNavigationEffects[sharedNavigationRevision] = navigation
            }
        } else if let (requestRevision, effect) = sharedNavigationEffects.first,
                  sharedStateReconciler.currentRevision == effect.revision {
            if case let .navigateVisible(target, _) = effect,
               observation.visiblePosition.map({ sharedPositionsMatch($0, target, source: desiredPosition.source) }) == true {
                sharedNavigationEffects.removeValue(forKey: requestRevision)
            }
        }

        sharedStateReconciler = reconciler
        let audioEffects = effects.filter { effect in
            switch effect {
            case .setPausedResumeAnchor, .realignNarration, .setRate, .startOrResume, .pause: true
            case .navigateVisible: false
            }
        }
            guard !audioEffects.isEmpty,
              let effectRevision = audioEffects.first?.revision,
              audioEffects.allSatisfy({ $0.revision == effectRevision }) else { return }
        sharedFollowerPlaybackTask?.cancel()
        let taskGeneration = UUID()
        sharedFollowerPlaybackGeneration = taskGeneration
        sharedRateRevision &+= 1
        let rateFence = SharedRateMutationFence(scopeID: sharedRateScopeID, revision: sharedRateRevision)
            sharedFollowerPlaybackTask = Task { @MainActor in
                guard sharedFollowerPlaybackGeneration == taskGeneration,
                  sharedIsFollowingController,
                  !sharedControlsLocked,
                  sharedStateReconciler.currentRevision == effectRevision,
                  !Task.isCancelled else { return }
            let rateNeedsApply = audioEffects.contains { if case .setRate = $0 { true } else { false } }
            let rateChanged = observation.effectiveRate.map { abs($0 - progress.ttsRate) > 0.0001 } ?? true
            let cursorNeedsRealignment = audioEffects.contains { if case .realignNarration = $0 { true } else { false } }
            let needsPausedAnchor = audioEffects.contains { if case .setPausedResumeAnchor = $0 { true } else { false } }
            let needsStart = audioEffects.contains { if case .startOrResume = $0 { true } else { false } }
            let desiredPlayback: SharedReadingDesiredPlayback = progress.isPlaying ? .playing : .paused
            let latestCursor = desiredPosition.desiredNarrationCursor
                ?? ((needsPausedAnchor || needsStart) ? desiredPosition.position : observation.narrationPosition)
            let plan = SharedFollowerAudioReconfigurationPlan.make(
                rate: progress.ttsRate,
                cursor: cursorNeedsRealignment || needsPausedAnchor || needsStart ? latestCursor : observation.narrationPosition,
                phase: desiredPlayback,
                rateChanged: rateChanged,
                cursorNeedsRealignment: cursorNeedsRealignment
            )
            guard rateNeedsApply || cursorNeedsRealignment || needsPausedAnchor || needsStart
                    || audioEffects.contains(where: { if case .pause = $0 { true } else { false } }) else { return }
            guard sharedFollowerPlaybackGeneration == taskGeneration,
                  sharedIsFollowingController,
                  !sharedControlsLocked,
                  sharedStateReconciler.currentRevision == effectRevision else { return }
            let controller = ensureReadAloudController()
            let cursor = plan.cursor.flatMap(sharedReadiumLocator)
            let restartAt = plan.restartAt.flatMap(sharedReadiumLocator)
            let succeeded = await controller.applySharedFollowerAudioReconfiguration(
                readerViewModel: vm,
                rate: plan.rate,
                cursor: cursor,
                phase: plan.phase,
                revision: effectRevision,
                rateFence: rateFence,
                restartAt: restartAt
            )
            guard sharedFollowerPlaybackGeneration == taskGeneration,
                  sharedIsFollowingController,
                  !sharedControlsLocked,
                  sharedStateReconciler.currentRevision == effectRevision,
                  !Task.isCancelled else { return }
            let local = sharedLocalObservation()
            var latestReconciler = sharedStateReconciler
            for effect in audioEffects {
                _ = latestReconciler.complete(effect, succeeded: succeeded, observation: local)
            }
            sharedStateReconciler = latestReconciler
            if succeeded, sharedRateScopeID == rateFence.scopeID {
                sharedRateScopeConfigured = true
            }
            if !succeeded {
                Log.sharedReading(.signalingEvent, level: .error, context: .init(
                    outcome: .failed,
                    sessionID: progress.sessionId,
                    roomEpoch: snapshot.roomEpoch.rawValue,
                    controllerGeneration: snapshot.controllerGeneration.rawValue,
                    connectionGeneration: snapshot.connectionGeneration.rawValue,
                    sequence: progress.sequence,
                    errorCode: "FOLLOWER_AUDIO_RECONCILIATION_FAILED"
                ))
            }
        }
    }

    @MainActor
    private func invalidateSharedFollowerWork(clearNavigation: Bool) {
        sharedFollowerPlaybackTask?.cancel()
        sharedFollowerPlaybackTask = nil
        sharedFollowerPlaybackGeneration = UUID()
        readAloudStartTask?.cancel()
        readAloudStartTask = nil
        readAloudStartRequest = UUID()
        sharedRateRevision &+= 1
        readAloud?.invalidateSharedFollowerEffects(
            fence: SharedRateMutationFence(scopeID: sharedRateScopeID, revision: sharedRateRevision)
        )
        sharedAcceptedProgress = nil
        sharedStateReconciler = SharedReadingStateReconciler()
        sharedNavigationEffects.removeAll()
        if clearNavigation {
            sharedNavigationRevision &+= 1
            sharedNavigationRequest = nil
        }
    }

    private var sharedObservedPlayback: SharedReadingObservedPlayback {
        switch readAloud?.localPlaybackPhase ?? .noSession {
        case .noSession: .noSession
        case let .playing(sessionID): .playing(sessionID)
        case let .paused(sessionID): .paused(sessionID)
        }
    }

    private func sharedLocalObservation() -> SharedReadingLocalObservation {
        SharedReadingLocalObservation(
            visiblePosition: sharedPosition(from: vm.visibleNavigatorLocator),
            narrationPosition: sharedPosition(from: readAloud?.currentNarrationLocator),
            playback: sharedObservedPlayback,
            effectiveRate: readAloud?.effectivePlaybackRate
        )
    }

    private func sharedPosition(from locator: Locator?) -> SharedReadingPosition? {
        guard let locator else { return nil }
        return SharedReadingPosition(
            href: locator.href.string,
            page: locator.locations.page,
            progression: locator.locations.progression
        )
    }

    private func sharedReadiumLocator(_ position: SharedReadingPosition) -> Locator? {
        if let narration = readAloud?.currentNarrationLocator, sharedPosition(from: narration) == position {
            return narration
        }
        if let visible = vm.visibleNavigatorLocator, sharedPosition(from: visible) == position {
            return visible
        }
        guard let progress = sharedAcceptedProgress else { return nil }
        let locator = (try? ReaderPositionLocator.decode(jsonString: progress.position))?.toReadiumLocator()
            ?? (try? Locator(jsonString: progress.position))
        guard let locator, sharedPosition(from: locator) == position else { return nil }
        return locator
    }

    private func sharedEncodedPosition(_ position: SharedReadingDesiredPosition) -> String? {
        guard let locator = sharedReadiumLocator(position.position) else { return nil }
        return try? ReaderPositionLocator(
            locator: locator,
            source: position.source == .readAloud ? .readAloud : .reader
        ).encodedJSONString()
    }

    private func sharedPositionsMatch(
        _ lhs: SharedReadingPosition,
        _ rhs: SharedReadingPosition,
        source: SharedReadingDesiredPosition.Source
    ) -> Bool {
        guard lhs.href == rhs.href, lhs.page == rhs.page else { return false }
        if source == .reader { return lhs.progression == rhs.progression }
        guard let left = lhs.progression, let right = rhs.progression else { return lhs.progression == rhs.progression }
        return abs(left - right) <= 0.08
    }

    private var sharedReadingProgressValue: String {
        let sequence = max(sharedLastSentSequence, sharedRemoteSequence)
        return sequence > 0 ? "sequence-\(sequence)" : "pending"
    }

    @ViewBuilder
    private var sharedReadingMicrophoneControls: some View {
        HStack(spacing: 8) {
            Button {
                sharedMicrophonePolicy = SharedReadingMicrophonePolicy.setMuted(
                    !sharedMicrophonePolicy.userMuted,
                    in: sharedMicrophonePolicy
                )
                applySharedMicrophonePolicy()
            } label: {
                Label(
                    sharedMicrophonePolicy.userMuted ? "Unmute" : "Mute",
                    systemImage: sharedMicrophonePolicy.userMuted ? "mic.slash.fill" : "mic.fill"
                )
            }
            .buttonStyle(.borderedProminent)

            if sharedTTSIsPlaying {
                Text("Hold to speak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in setSharedHoldToTalk(true) }
                            .onEnded { _ in setSharedHoldToTalk(false) }
                    )
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
    }

    private func setSharedHoldToTalk(_ holding: Bool) {
        guard sharedTTSIsPlaying else { return }
        sharedMicrophonePolicy = SharedReadingMicrophonePolicy.setHoldToTalk(holding, in: sharedMicrophonePolicy)
        if let sharedReadingCoordinator {
            Task {
                if holding {
                    try? await sharedReadingCoordinator.requestSpeaker()
                } else {
                    try? await sharedReadingCoordinator.releaseSpeaker()
                }
            }
        }
        applySharedMicrophonePolicy()
    }

    private func applySharedMicrophonePolicy() {
        guard let sharedReadingPeerMesh else { return }
        let enabled = sharedMicrophonePolicy.microphoneEnabled(isTTSPlaying: sharedTTSIsPlaying)
        Task { await sharedReadingPeerMesh.setMicrophoneEnabled(enabled) }
    }

    @MainActor
    private func forwardPaywallRequestIfNeeded() {
        guard let request = paywallRequestHandoff.takeAfterPromptDismissal() else { return }
        onRequestPaywall(request)
    }

    @MainActor
    private func ensureReadAloudController() -> ReadAloudController {
        if let readAloud { return readAloud }
        let controller = dependencies.playbackOwner.makeController(
            userId: userId,
            bookFileStorage: dependencies.bookFileStorage,
            onAllowanceFailure: { failure, sessionToken in
                pendingNarrationUpgradePrompt = readAloudUpgradeReason(for: failure)
                pendingNarrationUpgradeSessionToken = sessionToken
            },
            onReadAloudPositionChange: { locator in
                vm.didChangeReadAloudLocation(locator)
            },
            onPersistReadAloudPosition: { locator in
                vm.didChangeReadAloudLocation(locator)
                await vm.flush()
            },
            onFirstUtteranceFinished: { [weak readerTour] in
                readerTour?.firstUtteranceFinished()
            },
            onFirstUtteranceFailed: { [weak readerTour] in
                readerTour?.readAloudFailed()
            }
        )
        readAloud = controller
        return controller
    }

    @MainActor
    private func startReadAloud(from startLocator: Locator? = nil) {
        readAloudStartTask?.cancel()
        let request = UUID()
        let requestedSessionID = sharedAuthoritySessionID
        let requestedRoomEpoch = sharedAuthorityRoomEpoch
        let requestedControllerGeneration = sharedAuthorityControllerGeneration
        let requestedConnectionGeneration = sharedAuthorityConnectionGeneration
        readAloudStartRequest = request
        readAloudStartTask = Task { @MainActor in
            defer {
                if readAloudStartRequest == request {
                    readAloudStartTask = nil
                }
            }
            if let reason = await EntitlementAIGate.gateAIFeature(
                .narration,
                store: dependencies.entitlementSnapshotStore,
                coordinator: dependencies.entitlementRefreshCoordinator
            ) {
                pendingNarrationUpgradePrompt = reason
                readerTour?.readAloudFailed()
                return
            }

            guard !Task.isCancelled,
                  readAloudStartRequest == request,
                  !sharedIsFollowingController,
                  !sharedControlsLocked,
                  requestedSessionID == sharedAuthoritySessionID,
                  requestedRoomEpoch == sharedAuthorityRoomEpoch,
                  requestedControllerGeneration == sharedAuthorityControllerGeneration,
                  requestedConnectionGeneration == sharedAuthorityConnectionGeneration else {
                return
            }

            let controller = ensureReadAloudController()
            let result = await dependencies.playbackOwner.startWithGeneration(
                controller: controller,
                reader: vm,
                host: readAloudHost,
                from: startLocator
            )
            let requestIsCurrent = !Task.isCancelled
                && readAloudStartRequest == request
                && !sharedIsFollowingController
                && !sharedControlsLocked
                && requestedSessionID == sharedAuthoritySessionID
                && requestedRoomEpoch == sharedAuthorityRoomEpoch
                && requestedControllerGeneration == sharedAuthorityControllerGeneration
                && requestedConnectionGeneration == sharedAuthorityConnectionGeneration
            guard requestIsCurrent else {
                if result.started, let installedGeneration = result.generation {
                    await dependencies.playbackOwner.stop(
                        host: readAloudHost,
                        ifGeneration: installedGeneration
                    )
                }
                return
            }
            if !result.started { readerTour?.readAloudFailed() }
        }
    }

    @MainActor
    private func scheduleReaderIndexBackfillIfNeeded() async {
        guard !didScheduleReaderIndexBackfill else { return }
        guard await dependencies.bookSearch.status(bookId: vm.book.id).shouldBackfillIndex else {
            return
        }
        didScheduleReaderIndexBackfill = true
        guard let indexingHook = dependencies.indexingHook as? any AwaitableBookIndexingHook else {
            return
        }
        let book = vm.book
        let registry = dependencies.bookSourceRegistry
        let sourceLease = self.sourceLease
        Task {
            await ReaderIndexBackfillFence.scheduleAndDrain(
                book: book,
                sourceLease: sourceLease,
                resolveManagedSource: { try await registry.awaitManagedSource(for: book) },
                acquireManagedSource: { try await registry.acquireReadableSource(for: book) },
                indexingHook: indexingHook,
            )
        }
    }
}

func readAloudUpgradeReason(for failure: WorkerAllowanceError) -> AIFeatureBlockReason {
    failure.kind == .trial ? .trialExhausted : .narrationAllowanceExhausted
}

enum ReaderIndexBackfillFence {
    static func scheduleAndDrain(
        book: Book,
        sourceLease: BookSourceLease,
        resolveManagedSource: @escaping @Sendable () async throws -> ManagedBookSource,
        acquireManagedSource: @escaping @Sendable () async throws -> BookSourceLease,
        indexingHook: any AwaitableBookIndexingHook
    ) async {
        guard case let .account(permit) = sourceLease.access,
              permit.ownerID == book.userId,
              permit.bookID == book.id,
              let managed = try? await resolveManagedSource(),
              managed.bookID == book.id,
              managed.accountGeneration == permit.accountGeneration,
              managed.fingerprint.bookID == book.id,
              managed.fingerprint.ownerID == permit.ownerID,
              let managedLease = try? await acquireManagedSource(),
              case let .account(managedPermit) = managedLease.access,
              managedPermit.ownerID == permit.ownerID,
              managedPermit.accountGeneration == permit.accountGeneration,
              managedPermit.bookID == book.id,
              managedPermit.contentRevision == managed.fingerprint.version.materializationRevision,
              case let .managed(managedBookID, managedVersion) = managedLease.cachePolicy,
              managedBookID == book.id,
              managedVersion == managed.fingerprint.version,
              managedLease.url.standardizedFileURL == managed.url.standardizedFileURL,
              let managedAdmission = try? managedLease.effectAuthority.admit(managedLease.sourceAccessPermit)
        else { return }
        defer { managedAdmission.release() }

        await indexingHook.scheduleIndexingAndWait(for: book, fileURL: managedLease.url)
    }
}
