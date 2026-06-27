//


//







//

import Foundation
import OSLog
import RishiCore
import RishiAPI
import RishiAuth
import RishiBilling
import RishiChat
import RishiDB
import RishiLibrary
import RishiLogging
import RishiOnboarding
import RishiReader
import RishiSearch
import RishiSettings
import RishiSync
import RishiVoice


enum ServiceGraphFactory {

 
    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

 
    nonisolated static func build(
        userIdBox: UserIdBox
    ) async -> BootstrappedServices {
        
        let baseURLString = ProcessInfo.processInfo.environment["RISHI_API_URL"]
            ?? "https://api.fidexa.org"
        let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.fidexa.org")!

        
        let keychain = KeychainSessionStore()

        
        
        
        

        
        let tokenProvider = RishiAuthTokenProvider(keychain: keychain)

 
        let workerClient = WorkerClient(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
          
        )

        
        
        
        
        
        let siwaPresenter = await MainActor.run { SystemSiwaPresenter() }
        let siwaCoordinator = SignInWithAppleCoordinator(
            workerClient: workerClient,
            presenter: siwaPresenter
        )
        let authService = RishiAuthService(
            workerClient: workerClient,
            siwaCoordinator: siwaCoordinator,
            keychain: keychain
        )

        
        
        

        
        
        
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first!
        let dbURL = documentsURL.appendingPathComponent("rishi.sqlite")

        
        
        
        
        
        
        
        
        async let dbWriterTask: any DatabaseWriter = Self.openDatabaseWriter(at: dbURL)
        async let audioStackTask: AudioStack = AudioStackFactory.make(workerClient: workerClient)

        let dbQueue = await dbWriterTask

        
        let bookStore = GRDBBookStore(dbQueue: dbQueue)
        let positionStore = GRDBPositionStore(dbQueue: dbQueue)
        let highlightStore = GRDBHighlightStore(dbQueue: dbQueue)
        let bookmarkStore = GRDBBookmarkStore(dbQueue: dbQueue)

        
        let readerSettingsStore = UserDefaultsReaderSettingsStore()

        
        
        
        
        
        //
        
        
        
        
        
        
        
        
        let embedder: any BookEmbedder
        do {
            embedder = try CoreMLMiniLMEmbedder()
        } catch {
            Log.event("rag.embedder.fallback_identity", level: .warning, data: [
                "error": String(describing: error),
            ])
            embedder = IdentityEmbedder()
        }
        let indexBuilder = IndexBuilder(rootURL: documentsURL, embedder: embedder)
        
        
        
        
        
        let footerDetectionStore = UserDefaultsFooterDetectionStore()
        let pdfFooterPolicy: FooterDropPolicy =
            UserDefaults.standard.bool(forKey: UserDefaultsFooterDetectionStore.storageKey)
                ? .enabled
                : .disabled
        let indexingHook = RishiSearchIndexingHook(
            builder: indexBuilder,
            extractors: [
                "pdf": PdfTextExtractor(footerPolicy: pdfFooterPolicy),
                "epub": EpubTextExtractor(),
            ]
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

        
        let syncMetadataStore = GRDBSyncMetadataStore(dbQueue: dbQueue)
        let syncQueue = SyncQueue(metadataStore: syncMetadataStore)
        let syncStatus = SyncStatus()

        let bookUploader = BookUploader(
            workerClient: workerClient,
            metadataStore: syncMetadataStore,
            fileStorage: bookFileStorage,
            userIdProvider: { [keychain] in (try? await keychain.load())?.userId }
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

        
        
        let conversationStore = GRDBConversationStore(dbQueue: dbQueue)
        let messageStore = GRDBMessageStore(dbQueue: dbQueue)

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
        let changeApplier = ChangeApplier(
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            bookmarkStore: bookmarkStore,
            metadataStore: syncMetadataStore
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
            queue: syncQueue,
            metadataStore: syncMetadataStore,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            conversationUploader: conversationUploader,
            messageUploader: messageUploader,
            bookmarkUploader: bookmarkUploader,
            fetcher: remoteChangeFetcher,
            applier: changeApplier,
            conversationsFetcher: conversationsFetcher,
            messagesFetcher: messagesFetcher,
            conversationStore: conversationStore,
            messageStore: messageStore,
            chatRefreshDelegate: chatRefreshAdapter
        )

        
        
        
        let backgroundTaskCoordinator = await MainActor.run {
            BackgroundTaskCoordinator(engine: syncEngine)
        }
        let apnsDeviceRegistrar = APNsDeviceRegistrar(workerClient: workerClient)

        
        //
        
        
        
        
        
        
        
        
        
        //
        
        
        
        
        
        let pdfThumbnailCache = PDFThumbnailCache()
        let epubUnpackedCache = EPUBUnpackedCache()
        let bookPrewarmer = BookPrewarmer(
            pdfCache: pdfThumbnailCache,
            epubCache: epubUnpackedCache
        )
        let importCoordinator = ImportCoordinator(
            storage: bookFileStorage,
            currentUserId: {
                await authService.currentUser?.id
            },
            onBookImported: { [syncEngine, bookStore, bookFileStorage, bookPrewarmer] bookId in
                
                
                await syncEngine.markBookDirty(bookId)
                
                
                
                
                
                
                
                
                
                Task.detached(priority: .userInitiated) {
                    guard let book = try? await bookStore.book(bookId) else { return }
                    let url = await bookFileStorage.absoluteFileURL(for: book)
                    await bookPrewarmer.prewarm(book: book, fileURL: url)
                }
            }
        )

        
        let sampleBookInstaller = SampleBookInstaller(storage: bookFileStorage)
        let sampleReaderInstaller = SampleReaderInstaller(storage: bookFileStorage)

        
        
        
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
            conversationLookup: conversationLookup,
            conversationStore: conversationStore,
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

        

        
        
        
        
        
        
        
        
        let voicePresenter = await MainActor.run {

            return VoiceSessionPresenter(
                coordinator: audioStack.coordinator,
                workerClient: workerClient,
                messageStore: messageStore,
                conversationLookup: conversationLookup,
                userIdProvider: { [userIdBox] in userIdBox.value },
                dirtyHook: voiceDirtyAdapter,
                bookSearch: bookSearch,
                embedderPrewarm: embedderPrewarm
            )
        }

        
        let entitlementService = EntitlementService(workerClient: workerClient)
        let manageSubscriptionPresenter = await MainActor.run {
            ManageSubscriptionPresenter()
        }

        let storekitState = signposter.beginInterval("storekit.ready")
//        let productService = StoreKitProductService()
        let receiptVerifier: any ReceiptVerifier = {
         
            return WorkerReceiptVerifier(client: workerClient)
        }()
        
        
        
        
        
        
        
        
        
        let cachedEntitlement = await entitlementService.snapshot()
        let reconciler = await MainActor.run {
            let reconciler = EntitlementReconciler()
//            reconciler.setServer(cachedEntitlement)
            return reconciler
        }
//        let purchaseService = PurchaseService(
//            productFetcher: productService,
//            verifier: receiptVerifier,
//            reconciler: reconciler
//        )
     //   let listener = TransactionListener(forwarder: purchaseService)
        let entitlementFlag = await MainActor.run {
            ReaderAppEntitlementFlag(reconciler: reconciler)
        }
        let restoreService = RestoreService(reconciler: reconciler)
        signposter.endInterval("storekit.ready", storekitState)

        
//        Task.detached(priority: .background) { [purchaseService, listener, restoreService] in
//            await purchaseService.replayUnfinished()
//            await restoreService.refreshOnDeviceEntitlementAtLaunch()
//            await listener.start()
//        }
//        if StoreKitIAPFlag.isEnabled {
//            Task.detached(priority: .background) { [productService] in
//                _ = try? await productService.load()
//            }
//        }

        
        let telemetryStore = await MainActor.run {
            UserDefaultsTelemetryStore(sink: AppTelemetrySink())
        }

        
        let onboardingState = UserDefaultsOnboardingState()
        let onboardingCoordinator = await MainActor.run {
            OnboardingCoordinator(state: onboardingState)
        }

        
        let readerDefaults = await MainActor.run { AppReaderDefaults() }

        return BootstrappedServices(
            keychain: keychain,
            tokenProvider: tokenProvider,
            workerClient: workerClient,
            siwaPresenter: siwaPresenter,
            siwaCoordinator: siwaCoordinator,
            authService: authService,
            dbQueue: dbQueue,
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            bookmarkStore: bookmarkStore,
            bookFileStorage: bookFileStorage,
            importCoordinator: importCoordinator,
            sampleBookInstaller: sampleBookInstaller,
            sampleReaderInstaller: sampleReaderInstaller,
            readerSettingsStore: readerSettingsStore,
            audioCoordinator: audioStack.coordinator,
            ttsState: audioStack.state,
            ttsEngine: audioStack.engine,
            ttsSettingsStore: audioStack.settingsStore,
            nowPlayingController: audioStack.nowPlaying,
            ttsPrewarmer: audioStack.prewarmer,
            syncMetadataStore: syncMetadataStore,
            syncQueue: syncQueue,
            syncStatus: syncStatus,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            bookmarkUploader: bookmarkUploader,
            remoteChangeFetcher: remoteChangeFetcher,
            changeApplier: changeApplier,
            syncEngine: syncEngine,
            backgroundTaskCoordinator: backgroundTaskCoordinator,
            apnsDeviceRegistrar: apnsDeviceRegistrar,
            chatRefreshAdapter: chatRefreshAdapter,
            conversationStore: conversationStore,
            messageStore: messageStore,
            conversationLookup: conversationLookup,
            voiceDirtyAdapter: voiceDirtyAdapter,
            chatService: chatService,
            voicePresenter: voicePresenter,
            bookSearch: bookSearch,
            indexingHook: indexingHook,
//            entitlementService: entitlementService,
//            manageSubscriptionPresenter: manageSubscriptionPresenter,
//            storeKitProductService: productService,
//            purchaseService: purchaseService,
//            transactionListener: listener,
            entitlementReconciler: reconciler,
            readerAppEntitlementFlag: entitlementFlag,
            restoreService: restoreService,
            workerReceiptVerifier: receiptVerifier,
            telemetryStore: telemetryStore,
            footerDetectionStore: footerDetectionStore,
            onboardingState: onboardingState,
            onboardingCoordinator: onboardingCoordinator,
            readerDefaults: readerDefaults
        )
    }

    
    //
    
    
    
    

    nonisolated static func openDatabaseWriter(
        at dbURL: URL
    ) async -> any DatabaseWriter {
        let dbState = signposter.beginInterval("db.open")
        defer { signposter.endInterval("db.open", dbState) }
        do {
            return try RishiDB.makeDatabasePool(at: dbURL)
        } catch {
            fatalError("Failed to open rishi.sqlite at \(dbURL): \(error)")
        }
    }
}
