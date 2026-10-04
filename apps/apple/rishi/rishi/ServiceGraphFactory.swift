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

        #if DEBUG
        let isRealAuthUITest = ProcessInfo.processInfo.environment["RISHI_E2E_REAL_AUTH"] == "1"
        #else
        let isRealAuthUITest = false
        #endif
        let fallbackSpeechOptions = SpeechOptionsEndpoint.SpeechOptionsResponse(
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
        // The real-auth UI test signs in explicitly. Avoid blocking its
        // signed-out screen on optional launch-time network requests; the
        // normal production path still loads the server catalog here.
        async let speechOptionsTask: SpeechOptionsEndpoint.SpeechOptionsResponse = {
            if isRealAuthUITest {
                return fallbackSpeechOptions
            }
            return (try? await workerClient.send(SpeechOptionsEndpoint())) ?? fallbackSpeechOptions
        }()
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

        let speechOptions = await speechOptionsTask
        await MainActor.run {
            TTSPickerCatalogStore.shared.catalog = TTSPickerCatalog(
                voiceChoices: speechOptions.voices.map {
                    TTSVoiceChoice(id: $0.id, name: $0.name)
                },
                defaultVoiceID: speechOptions.defaultVoiceID
            )
        }

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
        let syncMetadataStore: SwiftDataSyncMetadataStore
        do {
            syncMetadataStore = try SyncMetadataStoreBootstrap.makeStore()
        } catch {
            fatalError("Failed to initialize sync metadata store: \(error)")
        }
        let bookSourceRegistry = BookSourceRegistry(
            persistence: bookImportPersistence,
            currentGeneration: { await fingerprintAccountGeneration() ?? 0 },
            currentOwnerID: { await userIdBox.value },
            managedURL: { book in documentsURL.appendingPathComponent(book.fileURL) }
        )
        let bookImportLifecycle = BookImportLifecycle(
            sourceRegistry: bookSourceRegistry,
            currentAccountGeneration: { await fingerprintAccountGeneration() }
        )
        let bookImportEvents = BookImportEvents()
        let bookMaterializationCoordinator = BookMaterializationCoordinator(
            rootURL: documentsURL,
            lifecycle: bookImportLifecycle,
            sourceRegistry: bookSourceRegistry,
            persistence: bookImportPersistence,
            bookStore: bookStore,
            currentGeneration: fingerprintAccountGeneration,
            isTombstoned: { bookId in
                (try? await syncMetadataStore.isTombstone(entityId: bookId, kind: .book)) ?? false
            },
            events: bookImportEvents
        )
        let bookImportRecovery = BookImportRecovery(
            rootURL: documentsURL,
            bookStore: bookStore,
            persistence: bookImportPersistence,
            lifecycle: bookImportLifecycle,
            prepareOwnedSourceCleanup: { token in
                await bookSourceRegistry.prepareOwnedSourceCleanup(for: token)
            },
            resume: { book, token in
                _ = try await bookMaterializationCoordinator.resumeRecovered(book: book, token: token)
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
            bookIndexingHook: indexingHook,
            isTombstoned: { bookId in
                (try? await syncMetadataStore.isTombstone(entityId: bookId, kind: .book)) ?? false
            },
            fingerprintPersistence: bookImportPersistence,
            fingerprintAccountGeneration: fingerprintAccountGeneration,
            materializationCoordinator: bookMaterializationCoordinator
        )
        if let ownerID = await userIdBox.value,
           let generation = await fingerprintAccountGeneration() {
            Task(priority: .background) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard await userIdBox.value == ownerID,
                      await fingerprintAccountGeneration() == generation,
                      let books = try? await bookStore.books(for: ownerID) else { return }
                for book in books {
                    guard !Task.isCancelled,
                          await userIdBox.value == ownerID,
                          await fingerprintAccountGeneration() == generation,
                          !((try? await syncMetadataStore.isTombstone(entityId: book.id, kind: .book)) ?? false),
                          FileManager.default.fileExists(atPath: bookFileStorage.absoluteFileURL(for: book).path) else { continue }
                    _ = await bookFileStorage.cacheVerifiedManagedFile(for: book)
                }
            }
        }
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
            userIdProvider: { [keychain] in
                if let session = try? await keychain.load() {
                    return session.userId
                }
                return try? Keychain.load(.userId)
            },
            managedSourceProvider: { book in
                guard let source = try await bookSourceRegistry.managedSource(for: book) else { return nil }
                return BookUploadSource(url: source.url, fingerprint: source.fingerprint)
            },
            currentGeneration: fingerprintAccountGeneration,
            persistServerAcceptance: { book, generation, fingerprint, acceptance in
                (try? await bookImportPersistence.recordServerAcceptance(
                    bookID: book.id,
                    ownerID: book.userId,
                    expectedGeneration: generation,
                    expectedContentRevision: fingerprint.version.materializationRevision,
                    acceptance: acceptance
                )) == true
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
            bookMaterializer: { book, r2Key, remoteFile in
                try await bookDownloadCoordinator.downloadAndMaterializeVerified(
                    book,
                    r2Key: r2Key,
                    expectedRemoteSHA256: remoteFile?.sha256,
                    expectedRemoteByteCount: remoteFile?.byteCount
                )
            },
            bookFingerprintPersister: { book, fingerprint in
                await bookFileStorage.persistVerifiedFingerprint(fingerprint, for: book)
            },
            prepareBookMaterialCleanup: { bookID, ownerID in
                try await bookFileStorage.prepareDeletionCleanup(bookID: bookID, ownerID: ownerID)
            },
            withBookDeletionAdmission: { ownerID, operation in
                guard await userIdBox.value == ownerID,
                      let generation = await fingerprintAccountGeneration(),
                      let lease = bookImportLifecycle.admitOwnerOperation(ownerID: ownerID, generation: generation) else {
                    throw CancellationError()
                }
                defer { lease.release() }
                guard await userIdBox.value == ownerID,
                      await fingerprintAccountGeneration() == generation else {
                    throw CancellationError()
                }
                try await operation(generation)
                guard await userIdBox.value == ownerID,
                      await fingerprintAccountGeneration() == generation else {
                    throw CancellationError()
                }
            },
            restoreBookAfterFailedRetirement: { book, generation in
                await bookMaterializationCoordinator.restoreBookAfterFailedRetirement(
                    book: book,
                    expectedGeneration: generation
                )
            },
            scheduleBookRecovery: { ownerID, generation in
                Task {
                    _ = try? await bookImportRecovery.recover(ownerID: ownerID, generation: generation) {
                        let currentOwner = await userIdBox.value
                        let currentGeneration = await fingerprintAccountGeneration()
                        return currentOwner == ownerID && currentGeneration == generation
                    }
                }
            },
            retireAndDrainBookForGeneration: { bookID, ownerID, generation in
                await bookImportLifecycle.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
                guard await userIdBox.value == ownerID,
                      await fingerprintAccountGeneration() == generation else { throw CancellationError() }
            },
            activateBook: { bookID in
                guard let ownerID = await userIdBox.value,
                      let generation = await fingerprintAccountGeneration() else { return }
                _ = bookSourceRegistry.activateBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
            },
            managedFingerprintLookup: { book in
                try? await bookSourceRegistry.managedSource(for: book)?.fingerprint
            },
            bookContentDigestLookup: { book in
                if let fingerprint = try? await bookImportPersistence.fingerprint(bookID: book.id, ownerID: book.userId) {
                    return fingerprint.sha256
                }
                if let pending = try? await bookImportPersistence.pendingMaterialization(bookID: book.id, ownerID: book.userId) {
                    return pending.expectedSHA256
                }
                return nil
            },
            hasPendingBookMaterialization: { book in
                (try? await bookImportPersistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)) != nil
            },
            bookServerAcceptancePersister: { book, fingerprint, acceptance in
                guard let generation = await fingerprintAccountGeneration() else { return false }
                return (try? await bookImportPersistence.recordServerAcceptance(
                    bookID: book.id,
                    ownerID: book.userId,
                    expectedGeneration: generation,
                    expectedContentRevision: fingerprint.version.materializationRevision,
                    acceptance: acceptance
                )) == true
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
            workerClient: workerClient
        )


        let pdfThumbnailCache = PDFThumbnailCache()
        let epubUnpackedCache = EPUBUnpackedCache()
        let bookPrewarmer = BookPrewarmer(
            pdfCache: pdfThumbnailCache,
            epubCache: epubUnpackedCache
        )
        let syncAfterBookImported: @Sendable (BookID) async -> Void = {
            [syncEngine, bookStore, bookSourceRegistry, bookPrewarmer] bookId in
            let markedDirty = await syncEngine.markBookDirty(bookId)

            Task.detached(priority: .userInitiated) {
                guard let book = try? await bookStore.book(bookId) else {
                    return
                }
                guard let managed = try? await bookSourceRegistry.awaitManagedSource(for: book) else { return }
                await bookPrewarmer.prewarm(book: book, fileURL: managed.url)
            }

            if markedDirty {
                await syncEngine.requestSync()
            }
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

        let voiceSessionCoordinator: any VoiceSessionCoordinating
        let voiceClientFactory: @MainActor () -> any RealtimeClientAPI
        let voiceControlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)?
        let micPermissionGate: any MicPermissionGate
        #if DEBUG
            if isUITest {
                voiceSessionCoordinator = UITestVoiceSessionCoordinator()
                voiceClientFactory = { UITestRealtimeClient() }
                voiceControlSocketFactory = { _, _ in nil }
                micPermissionGate = UITestMicPermissionGate()
            } else {
                let productionCoordinator = VoiceSessionAPIClient(workerClient: workerClient)
                voiceSessionCoordinator = productionCoordinator
                voiceClientFactory = { RealtimeAPIAdapter() }
                voiceControlSocketFactory = nil
                micPermissionGate = SystemMicPermissionGate()
            }
        #else
            voiceSessionCoordinator = VoiceSessionAPIClient(workerClient: workerClient)
            voiceClientFactory = { RealtimeAPIAdapter() }
            voiceControlSocketFactory = nil
            micPermissionGate = SystemMicPermissionGate()
        #endif
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
            VoiceSessionRegistry(
                currentUserIDProvider: { [userIdBox] in userIdBox.value },
                endServerSession: { id in
                    try await voiceSessionCoordinator.endSession(rishiSessionId: id)
                }
            )
        }
        let sharedReadingSessionRegistry = await MainActor.run {
            SharedReadingSessionRegistry { accountID in
                await PendingSessionInviteStore(accountId: accountID.uuidString).clear()
                await SharedSessionProgressStore(accountId: accountID.uuidString).clear()
                await ActiveReadingSessionStore(accountId: accountID.uuidString).clear()
            }
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
                micGate: micPermissionGate,
                bookSearch: bookSearch,
                embedderPrewarm: embedderPrewarm,
                chapterIndexCoordinatorFactory: chapterIndexCoordinatorFactory,
                chapterIndexContentVersionProvider: chapterIndexContentVersionProvider,
                clientFactory: voiceClientFactory,
                sessionCoordinatorFactory: { voiceSessionCoordinator },
                controlSocketFactory: voiceControlSocketFactory,
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
        EntitlementSyncHooks.workerClient = workerClient
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

        if !isRealAuthUITest, let userId = try? Keychain.load(.userId) {
            await entitlementService.bindToUser(userId: userId)
        }

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
            sharedReadingAPI: SharedReadingAPI(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                refreshAuthentication: { try await workerClient.refreshAuthentication() }
            ),
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
