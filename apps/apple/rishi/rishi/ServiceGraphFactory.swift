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
        userIdBox: UserIdBox
    ) async -> BootstrappedServices {

        let baseURLString =
            ProcessInfo.processInfo.environment["RISHI_API_URL"]
            ?? "https://api.fidexa.org"
        let baseURL =
            URL(string: baseURLString) ?? URL(string: "https://api.fidexa.org")!

        let keychain = KeychainSessionStore()

        let tokenProvider = RishiAuthTokenProvider(keychain: keychain)

        let dataUseConsentStore = UserDefaultsDataUseConsentStore()
        await dataUseConsentStore.setCurrentUser(await userIdBox.value.map(String.init))
        let dataUseConsentProvider = AccountDataUseConsentProvider(
            store: dataUseConsentStore,
            userIDProvider: { [userIdBox] in
                await userIdBox.value.map(String.init)
            }
        )

        let workerClient = WorkerClient(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            dataUseConsentProvider: dataUseConsentProvider,
        )

        let speechOptions = (try? await workerClient.send(SpeechOptionsEndpoint()))
            ?? SpeechOptionsEndpoint.SpeechOptionsResponse(
                provider: "openai",
                voices: VoiceCatalog.all.map {
                    .init(id: $0, name: VoiceCatalog.displayName(for: $0))
                },
                models: [
                    .init(id: "gpt-4o-mini-tts", name: "GPT-4o mini TTS")
                ],
                defaultVoiceID: VoiceCatalog.all.first ?? "marin",
                defaultModelID: "gpt-4o-mini-tts"
            )
        await MainActor.run {
            TTSPickerCatalogStore.shared.catalog = TTSPickerCatalog(
                voiceChoices: speechOptions.voices.map {
                    TTSVoiceChoice(id: $0.id, name: $0.name)
                },
                defaultVoiceID: speechOptions.defaultVoiceID
            )
        }

        let groupID = try? await GroupIDEndpoint().send()

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

        let bookStore = SwiftDataBookStore(dbStore: dbStore)
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
        let indexingHook = RishiSearchIndexingHook(
            builder: indexBuilder,
            extractors: [
                "pdf": PdfTextExtractor(footerPolicy: pdfFooterPolicy),
                "epub": EpubTextExtractor(),
            ],
            onIndexReady: { bookID in
                await chapterIndexGenerationDispatcher.refresh(bookID)
            }
        )
        let bookFileStorage = BookFileStorage(
            rootURL: documentsURL,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(),
                "epub": EpubCoverExtractor(),
            ],
            metadataExtractors: [
                "pdf": PDFKitMetadataExtractor(),
                "epub": EpubMetadataExtractor(),
            ],
            bookIndexingHook: indexingHook
        )

        let syncMetadataStore: SwiftDataSyncMetadataStore
        do {
            syncMetadataStore = try SyncMetadataStoreBootstrap.makeStore()
        } catch {
            fatalError("Failed to initialize sync metadata store: \(error)")
        }
        let syncQueue = SyncQueue(metadataStore: syncMetadataStore)
        let syncStatus = SyncStatus()

        let bookUploader = BookUploader(
            workerClient: workerClient,
            metadataStore: syncMetadataStore,
            fileStorage: bookFileStorage,
            userIdProvider: { [keychain] in
                if let session = try? await keychain.load() {
                    return session.userId
                }
                return try? Keychain.load(.userId)
            }
        )
        let positionUploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: syncMetadataStore
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
        let syncUserIdProvider: @Sendable () async -> String? = { [keychain] in
            if let session = try? await keychain.load() {
                return session.userId
            }
            return try? Keychain.load(.userId)
        }
        let bookDownloadCoordinator = BookDownloadCoordinator(
            workerClient: workerClient,
            fileStorage: bookFileStorage,
            userIdProvider: syncUserIdProvider
        )
        let changeApplier = ChangeApplier(
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            bookmarkStore: bookmarkStore,
            chapterIndexPersistence: chapterIndexPersistence,
            metadataStore: syncMetadataStore,
            currentUserId: { await userIdBox.value },
            accountIsActive: { await userIdBox.value != nil },
            bookMaterializer: { book, r2Key in
                try await bookDownloadCoordinator.downloadAndMaterialize(book, r2Key: r2Key)
            }
        )
        let conversationsFetcher = ConversationsFetcher(
            workerClient: workerClient,
            metadataStore: syncMetadataStore
        )
        let messagesFetcher = MessagesFetcher(
            workerClient: workerClient,
            metadataStore: syncMetadataStore
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
            dataUseConsentProvider: dataUseConsentProvider
            ),
            chatRefreshDelegate: chatRefreshAdapter
        )

        let backgroundTaskCoordinator = await MainActor.run {
            BackgroundTaskCoordinator(engine: syncEngine)
        }
        let apnsDeviceRegistrar = APNsDeviceRegistrar(
            workerClient: workerClient
        )


        let pdfThumbnailCache = PDFThumbnailCache()
        let epubUnpackedCache = EPUBUnpackedCache()
        let bookPrewarmer = BookPrewarmer(
            pdfCache: pdfThumbnailCache,
            epubCache: epubUnpackedCache
        )
        let importCoordinator = ImportCoordinator(
            storage: bookFileStorage,
            currentUserId: {
                await userIdBox.value
            },
            onBookImported: {
                [syncEngine, bookStore, bookFileStorage, bookPrewarmer] bookId
                in

                await syncEngine.markBookDirty(bookId)

                Task.detached(priority: .userInitiated) {
                    guard let book = try? await bookStore.book(bookId) else {
                        return
                    }
                    let url = bookFileStorage.absoluteFileURL(for: book)
                    await bookPrewarmer.prewarm(book: book, fileURL: url)
                }
            }
        )

        let sampleBookInstaller = SampleBookInstaller(storage: bookFileStorage)
        let sampleReaderInstaller = SampleReaderInstaller(
            storage: bookFileStorage
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

        let voiceSessionCoordinator = VoiceSessionAPIClient(workerClient: workerClient)
        let chapterIndexCache = ServiceGraphChapterIndexCoordinatorCache()
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
                    summarizer: ChapterSummarizer(
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
            VoiceSessionRegistry(
                endServerSession: { id in
                    try await voiceSessionCoordinator.endSession(rishiSessionId: id)
                }
            )
        }

        let voicePresenter = await MainActor.run {

            return VoiceSessionPresenter(
                coordinator: audioStack.coordinator,
                workerClient: workerClient,
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                dataUseConsentProvider: dataUseConsentProvider,
                messageStore: messageStore,
                conversationLookup: conversationLookup,
                userIdProvider: { [userIdBox] in userIdBox.value },
                dirtyHook: voiceDirtyAdapter,
                bookSearch: bookSearch,
                embedderPrewarm: embedderPrewarm,
                chapterIndexCoordinatorFactory: chapterIndexCoordinatorFactory,
                chapterIndexContentVersionProvider: chapterIndexContentVersionProvider,
                sessionCoordinatorFactory: { voiceSessionCoordinator },
                sessionRegistry: voiceSessionRegistry,
            )
        }

        let entitlementService = EntitlementService(workerClient: workerClient)
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
        let restoreService = RestoreService(reconciler: reconciler)
        let entitlementRefreshCoordinator = EntitlementRefreshCoordinator(
            entitlementService: entitlementService,
            launchRefresh: restoreService,
            signedInUserIdProvider: { try? Keychain.load(.userId) }
        )
        // Live SubscriptionStoreView path uses CustomerEntitlements →
        // syncEntitlement (not PurchaseService). Wire snapshot refresh so
        // gates/Settings update as soon as entitlement-sync succeeds.
        EntitlementSyncHooks.onSynced = { [entitlementRefreshCoordinator] in
            await entitlementRefreshCoordinator.refreshIfSignedIn(reason: .foreground)
        }
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

        if let userId = try? Keychain.load(.userId) {
            await entitlementService.bindToUser(userId: userId)
            await entitlementRefreshCoordinator.refreshIfSignedIn(reason: .launch)
        }

        return BootstrappedServices(
            workerClient: workerClient,
            dataUseConsentStore: dataUseConsentStore,
            library: LibraryRuntime(
                bookStore: bookStore,
                positionStore: positionStore,
                highlightStore: highlightStore,
                bookmarkStore: bookmarkStore,
                bookFileStorage: bookFileStorage,
                importCoordinator: importCoordinator,
                sampleBookInstaller: sampleBookInstaller,
                sampleReaderInstaller: sampleReaderInstaller,
                readerSettingsStore: readerSettingsStore,
                bookSearch: bookSearch,
                indexingHook: indexingHook
            ),
            audio: AudioRuntime(
                coordinator: audioStack.coordinator,
                ttsState: audioStack.state,
                ttsEngine: audioStack.engine,
                ttsSettingsStore: audioStack.settingsStore,
                nowPlayingController: audioStack.nowPlaying,
                ttsPresenceController: audioStack.presence,
                ttsPrewarmer: audioStack.prewarmer
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
