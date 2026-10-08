//

//

//

import Foundation
import CryptoKit
import OSLog
@preconcurrency import PDFKit
















enum ServiceGraphFactory {

    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

    nonisolated static func build(
        userIdBox: UserIdBox,
        credentialAuthority: SessionCredentialAuthority,
        admitCredentialRejection: @escaping @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission
    ) async throws -> BootstrappedServices {

        guard let apiEnvironment = RishiAPIEnvironment.load() else {
            fatalError("Rishi API endpoint configuration is missing or invalid")
        }
        let baseURL = apiEnvironment.httpBaseURL
        Log.event(
            "api.environment.selected",
            data: [
                "mode": apiEnvironment.mode.rawValue,
                "httpHost": baseURL.host ?? "unknown",
                "sharingWebSocketHost": apiEnvironment.sharingWebSocketURL.host ?? "unknown"
            ]
        )

        let dataUseConsentStore = UserDefaultsDataUseConsentStore(
            defaults: .standard, credentialAuthority: credentialAuthority)
        let dataUseConsentProvider = AccountDataUseConsentProvider(
            store: dataUseConsentStore, credentialAuthority: credentialAuthority)
        let workerClient = WorkerClient(
            baseURL: baseURL, session: .shared, credentialAuthority: credentialAuthority,
            dataUseConsentProvider: dataUseConsentProvider,
            admitCredentialRejection: admitCredentialRejection)


        async let groupIDTask = try? await GroupIDEndpoint().send(using: workerClient)

        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        let dbURL = documentsURL.appendingPathComponent("rishi.sqlite")

        async let dbStoreTask: RishiDBStore = Self.openPersistenceStore(
            at: dbURL
        )
        async let audioStackTask: AudioStack = AudioStackFactory.make(
            workerClient: workerClient,
            dataUseConsentProvider: dataUseConsentProvider
        )

        let dbStore = await dbStoreTask
        let scopedMutationStore = BookScopedMutationStore(dbStore: dbStore)

        let bookStore = SwiftDataBookStore(dbStore: dbStore)
        let bookImportPersistence = SwiftDataBookImportPersistence(
            dbStore: dbStore,
            managedFileRootURL: documentsURL
        )
        let fingerprintAccountGeneration: @Sendable () async -> UInt64? = {
            (UserDefaults.standard.object(forKey: "rishi.account.generation") as? NSNumber)?.uint64Value
        }
        if let ownerID = await userIdBox.value,
           let generation = await fingerprintAccountGeneration() {
            try? await bookImportPersistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        }
        let positionStore = SwiftDataPositionStore(dbStore: dbStore)
        let highlightStore = SwiftDataHighlightStore(dbStore: dbStore)
        let bookmarkStore = SwiftDataBookmarkStore(dbStore: dbStore)

        let readerSettingsStore = UserDefaultsReaderSettingsStore()

        //

        let embedder: any BookEmbedder
        do {
            embedder = try CoreMLMiniLMEmbedder()
        } catch {
            Log.event(
                "rag.embedder.fallback_identity",
                level: .warning,
                data: [
                    "error": String(describing: error)
                ]
            )
            embedder = IdentityEmbedder()
        }
        let indexBuilder = IndexBuilder(
            rootURL: documentsURL,
            embedder: embedder
        )

        let footerDetectionStore = UserDefaultsFooterDetectionStore()
        let pdfFooterPolicy: FooterDropPolicy =
            UserDefaults.standard.bool(
                forKey: UserDefaultsFooterDetectionStore.storageKey
            )
            ? .enabled
            : .disabled
        let chapterIndexGenerationDispatcher = ChapterIndexGenerationDispatcher()
        let syncMetadataStore: SwiftDataSyncMetadataStore
        do {
            syncMetadataStore = try await SyncMetadataStoreBootstrap.makeStore()
        } catch {
            fatalError("Failed to initialize sync metadata store: \(error)")
        }
        let bookDomain = await BookDomainFactory.make(
            documentsURL: documentsURL, bookStore: bookStore, bookImportPersistence: bookImportPersistence,
            syncMetadataStore: syncMetadataStore, userIdBox: userIdBox,
            fingerprintAccountGeneration: fingerprintAccountGeneration, indexBuilder: indexBuilder,
            pdfFooterPolicy: pdfFooterPolicy, chapterIndexGenerationDispatcher: chapterIndexGenerationDispatcher
        )
        let bookSourceRegistry = bookDomain.sources
        let indexingHook = bookDomain.indexing
        let bookImportLifecycle = bookDomain.lifecycle
        let bookImportEvents = bookDomain.events
        let bookMaterializationCoordinator = bookDomain.materialization
        let bookFileStorage = bookDomain.files
        let bookImportRecovery = bookDomain.recovery
        let sessionBookService = SessionBookService(
            fileStorage: bookFileStorage,
            userIdProvider: { await userIdBox.value }
        )
        let syncQueue = SyncQueue(metadataStore: syncMetadataStore)
        let syncStatus = SyncStatus()

        let bookUploader = BookUploader(
            workerClient: workerClient,
            metadataStore: syncMetadataStore,
            fileStorage: bookFileStorage,
            userIdProvider: { (try? credentialAuthority.snapshot())?.lease.rawUserID },
            managedSourceProvider: { book in
                guard let source = try await bookSourceRegistry.managedSource(for: book) else { return nil }
                return BookUploadSource(url: source.url, fingerprint: source.fingerprint, readingPermit: source.readingPermit)
            },
            persistServerAcceptance: { permit, fingerprint, acceptance in
                (try? await bookImportPersistence.recordServerAcceptance(
                    permit: permit,
                    expectedFingerprint: fingerprint,
                    acceptance: acceptance
                )) == true
            }
        )
        let positionUploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: syncMetadataStore,
            currentUserId: { await userIdBox.value }
        )
        let highlightUploader = HighlightUploader(
            workerClient: workerClient,
            highlightStore: highlightStore,
            metadataStore: syncMetadataStore
        )

        let bookmarkUploader = BookmarkUploader(
            workerClient: workerClient,
            bookmarkStore: bookmarkStore,
            metadataStore: syncMetadataStore
        )
        let chapterIndexPersistence = ServiceGraphChapterIndexPersistence(store: bookStore, metadataStore: syncMetadataStore, queue: syncQueue)
        let chapterIndexUploader = ChapterIndexUploader(
            workerClient: workerClient,
            bookStore: bookStore,
            persistence: chapterIndexPersistence,
            metadataStore: syncMetadataStore
        )

        let conversationStore = SwiftDataConversationStore(dbStore: dbStore)
        let messageStore = SwiftDataMessageStore(dbStore: dbStore)

        let conversationUploader = ConversationUploader(
            workerClient: workerClient,
            conversationStore: conversationStore,
            metadataStore: syncMetadataStore
        )
        let messageUploader = MessageUploader(
            workerClient: workerClient,
            messageStore: messageStore,
            metadataStore: syncMetadataStore
        )

        let remoteChangeFetcher = RemoteChangeFetcher(
            workerClient: workerClient,
            metadataStore: syncMetadataStore
        )
        let syncUserIdProvider: @Sendable () async -> String? = {
            (try? credentialAuthority.snapshot())?.lease.rawUserID
        }
        let isCurrentAccountPermit: @Sendable (AccountMutationPermit) async -> Bool = { permit in
            await bookDomain.isCurrentAccountPermit(permit)
        }
        let admitAccountOperation: @Sendable (AccountMutationPermit) async -> BookImportOperationLease? = { permit in
            await bookDomain.admitAccountOperation(permit)
        }
        let bookDownloadCoordinator = BookDownloadCoordinator(
            workerClient: workerClient,
            fileStorage: bookFileStorage,
            userIdProvider: syncUserIdProvider,
            metadataStore: syncMetadataStore,
            isCurrentAccountPermit: isCurrentAccountPermit,
            admitAccountOperation: admitAccountOperation
        )
        let bookSyncIntegration = BookSyncIntegration(domain: bookDomain, download: bookDownloadCoordinator)
        let changeApplier = ChangeApplier(
            bookStore: bookStore, positionStore: positionStore, highlightStore: highlightStore,
            bookmarkStore: bookmarkStore, chapterIndexPersistence: chapterIndexPersistence,
            metadataStore: syncMetadataStore, bookIntegration: bookSyncIntegration
        )
        let conversationsFetcher = ConversationsFetcher(
            workerClient: workerClient,
            metadataStore: syncMetadataStore
        )
        let messagesFetcher = MessagesFetcher(
            workerClient: workerClient,
            metadataStore: syncMetadataStore
        )
        let localSyncObjectBuilder = LocalSyncObjectBuilder(
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            bookmarkStore: bookmarkStore,
            metadataStore: syncMetadataStore,
            localUserIdProvider: { await userIdBox.value },
            workerUserIdProvider: syncUserIdProvider
        )

        let chatRefreshAdapter = AppChatRefreshAdapter()

        let syncEngine = SyncEngine(
            config: .init(),
            dependencies: .init(
            queue: syncQueue,
            metadataStore: syncMetadataStore,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            conversationUploader: conversationUploader,
            messageUploader: messageUploader,
            bookmarkUploader: bookmarkUploader,
            chapterIndexUploader: chapterIndexUploader,
            fetcher: remoteChangeFetcher,
            applier: changeApplier,
            conversationsFetcher: conversationsFetcher,
            messagesFetcher: messagesFetcher,
            conversationStore: conversationStore,
            messageStore: messageStore,
            dataUseConsentProvider: dataUseConsentProvider,
            currentUserId: { await userIdBox.value },
            localSyncObjectBuilder: localSyncObjectBuilder,
            bookReadinessPolicy: BookReadinessPolicy(
                bookStore: bookStore,
                positionStore: positionStore,
                highlightStore: highlightStore,
                bookmarkStore: bookmarkStore,
                conversationStore: conversationStore,
                messageStore: messageStore,
                chapterIndexes: chapterIndexPersistence,
                metadataStore: syncMetadataStore,
                sourceResolver: bookSourceRegistry,
                currentUserID: { await userIdBox.value }
            )
            ),
            chatRefreshDelegate: chatRefreshAdapter
        )

        let backgroundTaskCoordinator = await MainActor.run {
            BackgroundTaskCoordinator(engine: syncEngine)
        }
        let apnsDeviceRegistrar = APNsDeviceRegistrar(
            workerClient: workerClient, credentialAuthority: credentialAuthority
        )


        let pdfThumbnailCache = PDFThumbnailCache()
        let epubUnpackedCache = EPUBUnpackedCache()
        let bookPrewarmer = BookPrewarmer(
            pdfCache: pdfThumbnailCache,
            epubCache: epubUnpackedCache
        )
        let syncAfterBookImported: @Sendable (BookID) async -> Void = { bookID in
            await bookDomain.syncAfterBookImported(bookID, engine: syncEngine, prewarmer: bookPrewarmer)
        }
        let importCoordinator = ImportCoordinator(
            storage: bookFileStorage,
            currentUserId: {
                await userIdBox.value
            },
            lifecycle: bookImportLifecycle,
            onBookImported: syncAfterBookImported
        )

        let sharePackageService = SharePackageService(
            workerClient: workerClient,
            bookStore: bookStore,
            fileStorage: bookFileStorage,
            syncEngine: syncEngine,
            currentUserId: { await userIdBox.value },
            managedFingerprintProvider: { book in
                try? await bookSourceRegistry.managedSource(for: book)?.fingerprint
            },
            awaitManagedFingerprintProvider: { book in
                try await bookSourceRegistry.awaitManagedSource(for: book).fingerprint
            }
        )

        let sampleBookInstaller = SampleBookInstaller(
            storage: bookFileStorage,
            onBookImported: syncAfterBookImported
        )
        let sampleReaderInstaller = SampleReaderInstaller(
            storage: bookFileStorage,
            onBookImported: syncAfterBookImported
        )

        Task { [syncEngine, syncStatus] in
            await syncEngine.bind(status: syncStatus)
        }

        let audioStack = await audioStackTask

        let conversationLookup = ConversationLookup(store: conversationStore)
        let voiceDirtyAdapter = AppVoiceDirtyAdapter(syncEngine: syncEngine)
        let chatService = RishiChatService(
            userIdProvider: { @Sendable [userIdBox] in
                await userIdBox.value
            },
            workerClient: workerClient,
            dataUseConsentProvider: dataUseConsentProvider,
            conversationLookup: conversationLookup,
            messageStore: messageStore,
            dirtyHook: voiceDirtyAdapter
        )

        let bookSearch = USearchBookSearch(
            rootURL: documentsURL,
            embedder: embedder,
            k: 3
        )
        let embedderForPrewarm = embedder
        let embedderPrewarm: @Sendable () async -> Void = {
            await embedderForPrewarm.prewarm()
        }

        #if DEBUG
            let isUITest = ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1"
        #else
            let isUITest = false
        #endif

        let voiceClientFactory: @MainActor () -> any RealtimeClientAPI
        let micPermissionGate: any MicPermissionGate
        #if DEBUG
        if isUITest {
            voiceClientFactory = { UITestRealtimeClient() }
            micPermissionGate = UITestMicPermissionGate()
        } else {
            voiceClientFactory = { RealtimeAPIAdapter() }
            micPermissionGate = SystemMicPermissionGate()
        }
        #else
        voiceClientFactory = { RealtimeAPIAdapter() }
        micPermissionGate = SystemMicPermissionGate()
        #endif
        let voiceSessionAPIFactory: @MainActor (CredentialRequestContext) throws -> VoiceSessionAPIClient = { context in
            try VoiceSessionAPIClient(workerClient: workerClient, credentialAuthority: credentialAuthority,
                                      credentialContext: context, baseURL: baseURL, session: .shared,
                                      dataUseConsentProvider: dataUseConsentProvider)
        }
        let controlSocketFactory: RealtimeVoiceSession.ScopedControlSocketFactory = { id, context, terminal in
            try ControlWebSocketClient(baseURL: baseURL, credentialAuthority: credentialAuthority,
                credentialContext: context, dataUseConsentProvider: dataUseConsentProvider,
                rishiSessionId: id, urlSession: .shared, onTerminal: terminal)
        }
        let chapterIndexCache = ServiceGraphChapterIndexCoordinatorCache()
        let chapterSummarizer = ChapterSummarizer(
            local: {
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macCatalyst 26.0, *) {
                    AppleFoundationModelsChapterSummarizerProvider()
                } else {
                    nil
                }
                #else
                nil
                #endif
            }(),
            fallback: WorkerChapterSummarizerProvider(workerClient: workerClient)
        )
        let chapterIndexContentVersionProvider: @Sendable (BookID) async -> String? = { bookId in
            guard let book = try? await bookStore.book(bookId) else { return nil }
            let url = bookFileStorage.absoluteFileURL(for: book)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return String("chapter-source-v1-\(digest)".prefix(128))
        }
        let chapterIndexCoordinatorFactory: RealtimeVoiceSession.ChapterIndexCoordinatorFactory = { bookId, contentVersion in
            guard let book = try? await bookStore.book(bookId) else { return nil }
            return await chapterIndexCache.coordinator(bookID: bookId, contentVersion: contentVersion) {
                ChapterIndexCoordinator(
                    persistence: chapterIndexPersistence,
                    source: ServiceGraphChapterSource(book: book, storage: bookFileStorage),
                    summarizer: chapterSummarizer
                )
            }
        }
        await chapterIndexGenerationDispatcher.configure { bookID in
            guard
                let book = try? await bookStore.book(bookID),
                let contentVersion = await chapterIndexContentVersionProvider(bookID),
                let coordinator = await chapterIndexCoordinatorFactory(bookID, contentVersion)
            else { return }
            _ = try? await coordinator.waitForCompletion(
                bookID: book.id,
                contentVersion: contentVersion
            )
        }
        let voiceSessionRegistry = await MainActor.run {
            VoiceSessionRegistry(defaults: .standard, credentialAuthority: credentialAuthority,
                currentUserIDProvider: { [userIdBox] in userIdBox.value }, sessionAPIFactory: voiceSessionAPIFactory)
        }
        let sharedReadingSessionRegistry = await MainActor.run {
            SharedReadingSessionRegistry { accountID in
                await PendingSessionInviteStore(accountId: accountID.uuidString).clear()
                await SharedSessionProgressStore(accountId: accountID.uuidString).clear()
                await ActiveReadingSessionStore(accountId: accountID.uuidString).clear()
            }
        }

        let voicePresenter = try await MainActor.run {

            return try VoiceSessionPresenter(
                coordinator: audioStack.coordinator,
                workerClient: workerClient,
                baseURL: baseURL,
                dataUseConsentProvider: dataUseConsentProvider,
                messageStore: messageStore,
                conversationLookup: conversationLookup,
                userIdProvider: { [userIdBox] in userIdBox.value },
                dirtyHook: voiceDirtyAdapter,
                micGate: micPermissionGate,
                bookSearch: bookSearch,
                embedderPrewarm: embedderPrewarm,
                chapterIndexCoordinatorFactory: chapterIndexCoordinatorFactory,
                chapterIndexContentVersionProvider: chapterIndexContentVersionProvider,
                clientFactory: voiceClientFactory,
                credentialAuthority: credentialAuthority,
                sessionAPIFactory: voiceSessionAPIFactory,
                scopedControlSocketFactory: controlSocketFactory,
                sessionRegistry: voiceSessionRegistry
            )
        }

        let entitlementService = EntitlementService(workerClient: workerClient, defaults: .standard, credentialAuthority: credentialAuthority)
        let entitlementSnapshotStore = await MainActor.run {
            EntitlementSnapshotStore(service: entitlementService)
        }
        let manageSubscriptionPresenter = await MainActor.run {
            ManageSubscriptionPresenter()
        }

        let storekitState = signposter.beginInterval("storekit.ready")
        let receiptVerifier: any ReceiptVerifier = {

            return WorkerReceiptVerifier(client: workerClient)
        }()

        let _ = await entitlementService.snapshot()
        let reconciler = await MainActor.run {
            let reconciler = EntitlementReconciler()
            //            reconciler.setServer(cachedEntitlement)
            return reconciler
        }

        let entitlementFlag = await MainActor.run {
            ReaderAppEntitlementFlag(reconciler: reconciler)
        }
        let entitlementSyncClient = EntitlementSyncClient(client: workerClient)
        let restoreService = try RestoreService(reconciler: reconciler, entitlementSyncClient: entitlementSyncClient,
                                                credentialAuthority: credentialAuthority)
        let entitlementRefreshCoordinator = try EntitlementRefreshCoordinator(
            entitlementService: entitlementService,
            launchRefresh: restoreService,
            credentialAuthority: credentialAuthority
        )
        let customerEntitlements = try await MainActor.run {
            try CustomerEntitlements(credentialAuthority: credentialAuthority,
                entitlementSyncClient: entitlementSyncClient, workerClient: workerClient,
                refreshCoordinator: entitlementRefreshCoordinator)
        }
        let store = await MainActor.run { Store(customerEntitlements: customerEntitlements) }
        signposter.endInterval("storekit.ready", storekitState)

        let telemetryStore = await MainActor.run {
            UserDefaultsTelemetryStore(sink: AppTelemetrySink())
        }

        let onboardingState = UserDefaultsOnboardingState()
        let trialOnboardingState = UserDefaultsTrialOnboardingState()
        let onboardingCoordinator = await MainActor.run {
            OnboardingCoordinator(state: onboardingState)
        }

        let readerDefaults = await MainActor.run { AppReaderDefaults() }

        let groupID = await groupIDTask

        let spotlightIndexingClient: any RishiSearchIndexingClient = {
            #if targetEnvironment(macCatalyst)
            RishiNoopSpotlightIndexingClient()
            #else
            RishiCoreSpotlightIndexingClient()
            #endif
        }()
        let spotlightCoordinator = RishiSpotlightCoordinator(
            bookStore: bookStore,
            highlightStore: highlightStore,
            conversationStore: conversationStore,
            currentUserID: { await userIdBox.value },
            indexingClient: spotlightIndexingClient
        )

        return BootstrappedServices(
            workerClient: workerClient,
            sharedReadingAPIFactory: { context in
                try SharedReadingAPI(baseURL: baseURL, session: .shared,
                    credentialAuthority: credentialAuthority, workerClient: workerClient,
                    credentialContext: context)
            },
            sharedReadingSessionRegistry: sharedReadingSessionRegistry,
            dataUseConsentStore: dataUseConsentStore,
            library: LibraryRuntime(
                dbStore: dbStore,
                scopedMutationStore: scopedMutationStore,
                bookStore: bookStore,
                positionStore: positionStore,
                highlightStore: highlightStore,
                bookmarkStore: bookmarkStore,
                bookFileStorage: bookFileStorage,
                importCoordinator: importCoordinator,
                sampleBookInstaller: sampleBookInstaller,
                sampleReaderInstaller: sampleReaderInstaller,
                readerSettingsStore: readerSettingsStore,
                chapterIndexPersistence: chapterIndexPersistence,
                chapterSummarizer: chapterSummarizer,
                epubUnpackedCache: epubUnpackedCache,
                bookSearch: bookSearch,
                indexingHook: indexingHook,
                sharePackageService: sharePackageService,
                sessionBookService: sessionBookService,
                bookSourceRegistry: bookSourceRegistry,
                bookImportLifecycle: bookImportLifecycle,
                bookMaterializationCoordinator: bookMaterializationCoordinator,
                bookImportEvents: bookImportEvents,
                currentAccountGeneration: fingerprintAccountGeneration,
                bookImportRecovery: bookImportRecovery
            ),
            audio: AudioRuntime(
                coordinator: audioStack.coordinator,
                ttsState: audioStack.state,
                ttsEngine: audioStack.engine,
                ttsSettingsStore: audioStack.settingsStore,
                nowPlayingController: audioStack.nowPlaying,
                ttsPresenceController: audioStack.presence,
                ttsPrewarmer: audioStack.prewarmer,
                playbackOwner: await MainActor.run {
                    ReadAloudPlaybackOwner(
                        ttsEngine: audioStack.engine,
                        ttsState: audioStack.state,
                        ttsSettingsStore: audioStack.settingsStore,
                        ttsPrewarmer: audioStack.prewarmer,
                        ttsPresence: audioStack.presence,
                        coordinator: audioStack.coordinator,
                        nowPlayingController: audioStack.nowPlaying
                    )
                }
            ),
            sync: SyncRuntime(
                metadataStore: syncMetadataStore,
                status: syncStatus,
                engine: syncEngine,
                backgroundTaskCoordinator: backgroundTaskCoordinator,
                chapterIndexGenerationDispatcher: chapterIndexGenerationDispatcher,
                apnsDeviceRegistrar: apnsDeviceRegistrar,
                chatRefreshAdapter: chatRefreshAdapter
            ),
            chat: ChatRuntime(
                conversationStore: conversationStore,
                messageStore: messageStore,
                conversationLookup: conversationLookup,
                service: chatService
            ),
            voice: VoiceRuntime(
                presenter: voicePresenter,
                sessionRegistry: voiceSessionRegistry
            ),
            billing: BillingRuntime(
                customerEntitlements: customerEntitlements,
                store: store,
                entitlementService: entitlementService,
                entitlementSnapshotStore: entitlementSnapshotStore,
                entitlementRefreshCoordinator: entitlementRefreshCoordinator,
                manageSubscriptionPresenter: manageSubscriptionPresenter,
                entitlementReconciler: reconciler,
                readerAppEntitlementFlag: entitlementFlag,
                restoreService: restoreService,
                workerReceiptVerifier: receiptVerifier,
                groupID: groupID
            ),
            settings: SettingsRuntime(
                readerDefaults: readerDefaults,
                telemetryStore: telemetryStore,
                footerDetectionStore: footerDetectionStore
            ),
            onboarding: OnboardingRuntime(
                state: onboardingState,
                trialState: trialOnboardingState,
                coordinator: onboardingCoordinator
            ),
            systemIntegration: SystemIntegrationRuntime(spotlight: spotlightCoordinator),
        )
    }

    

    nonisolated static func openPersistenceStore(
        at dbURL: URL
    ) async -> RishiDBStore {
        let dbState = signposter.beginInterval("db.open")
        defer { signposter.endInterval("db.open", dbState) }
        do {
            return try RishiDB.makeStore(at: dbURL)
        } catch {
            fatalError("Failed to open rishi.sqlite at \(dbURL): \(error)")
        }
    }
}

private struct ServiceGraphChapterIndexPersistence: ChapterIndexPersistence {
    let store: SwiftDataBookStore
    let metadataStore: SwiftDataSyncMetadataStore
    let queue: SyncQueue

    func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? {
        try await store.chapterIndex(bookID: bookID, contentVersion: contentVersion)
    }

    func upsertChapterIndex(_ index: ChapterIndex) async throws {
        try await store.upsertChapterIndex(index)
    }

    func markChapterIndexDirty(bookID: BookID) async throws {
        try await metadataStore.markDirty(entityId: bookID, kind: .chapterIndex)
        await queue.enqueue(SyncQueueItem(entityId: bookID, kind: .chapterIndex))
    }
}

private actor ServiceGraphChapterIndexCoordinatorCache {
    private struct Entry: Sendable {
        let contentVersion: String
        let coordinator: ChapterIndexCoordinator
    }

    private var values: [BookID: Entry] = [:]

    func coordinator(
        bookID: BookID,
        contentVersion: String,
        make: @Sendable () -> ChapterIndexCoordinator
    ) -> ChapterIndexCoordinator {
        if let existing = values[bookID], existing.contentVersion == contentVersion {
            return existing.coordinator
        }
        let created = make()
        // A new content version supersedes the previous generation for this
        // book, keeping the service-graph cache bounded.
        values[bookID] = Entry(contentVersion: contentVersion, coordinator: created)
        return created
    }
}

private struct ServiceGraphChapterSource: ChapterSource {
    let book: Book
    let storage: BookFileStorage

    func chapters() async -> ChapterSourceResult {
        let fileURL = storage.absoluteFileURL(for: book)
        switch book.formatType {
        case .epub:
            do {
                let publication = try await PublicationLoader().open(fileURL: fileURL)
                return await EPUBChapterSource.snapshot(from: publication)
            } catch {
                return ChapterSourceResult(
                    availability: .unavailable(diagnostics: ["EPUB could not be opened: \(error)"]),
                    records: []
                )
            }
        case .pdf:
            guard let document = PDFDocument(url: fileURL) else {
                return ChapterSourceResult(
                    availability: .unavailable(diagnostics: ["PDF could not be opened"]),
                    records: []
                )
            }
            return await PDFChapterSource.snapshot(from: document)
        case .mobi, .azw3:
            return ChapterSourceResult(
                availability: .unavailable(diagnostics: ["This book format has no chapter source adapter"]),
                records: []
            )
        }
    }
}
