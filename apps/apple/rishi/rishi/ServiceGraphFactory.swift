//
//  ServiceGraphFactory.swift
//  rishi
//
//  Plan 34-14 SRP split — extracts the off-main service-graph construction
//  out of `AppDependencies`. `AppDependencies` is now a thin service-only
//  container that delegates the heavy `buildServices` routine to this
//  factory. Behaviour-preserving move: the construction body, the Wave-A
//  `async let` race (DB open vs audio-stack alloc), every `#if DEBUG` UITest
//  branch, and the `BootstrappedServices` aggregate are unchanged. Audio
//  construction is delegated to `AudioStackFactory`.
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

/// Off-main composition-root factory. Owns the procedural service-graph
/// construction that previously lived inside `AppDependencies.buildServices`.
/// Every member is `nonisolated` so the work runs on the detached executor
/// (`AppDependencies.bootstrap()` wraps the call in `Task.detached`); the
/// handful of MainActor-isolated objects (SwiftUI presenters, `@Observable`
/// view models, `BackgroundTaskCoordinator`) are constructed via explicit
/// `await MainActor.run { ... }` hops exactly as before.
enum ServiceGraphFactory {

    /// Signposter for the cold-launch trace. Mirrors the one on
    /// `AppDependencies` so the nested `db.open` / `storekit.ready`
    /// intervals attribute time to each hotspot during bootstrap.
    /// `nonisolated` so the off-main builder can begin/end intervals without
    /// hopping to MainActor. OSSignposter is `Sendable` (Swift 6).
    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

    /// Off-main service-graph builder. Invoked from inside `Task.detached`
    /// (off-main) by `AppDependencies.makeServices(userIdBox:)`. Hops onto
    /// MainActor only for the small subset of objects whose initialisers are
    /// MainActor-isolated upstream (SwiftUI presenters, `@Observable`
    /// view models, `BackgroundTaskCoordinator`). The bulk of the work —
    /// GRDB queue open + migrations, AVAudioEngine alloc, StoreKit graph
    /// — runs nonisolated on the detached executor.
    nonisolated static func build(
        userIdBox: UserIdBox
    ) async -> BootstrappedServices {
        // Worker base URL (override via env for staging tests).
        let baseURLString = ProcessInfo.processInfo.environment["RISHI_API_URL"]
            ?? "https://api.fidexa.org"
        let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.fidexa.org")!

        // 1. Keychain — single instance backing the token provider AND the auth service.
        let keychain = KeychainSessionStore()

        // UITEST — seed a fake authenticated session into the keychain BEFORE
        // the auth probe (RootView bootstrap `.task` → `auth.currentUser`)
        // runs, so `RootView.currentUser` resolves non-nil fully offline and
        // signed-out. DEBUG + `RISHI_UITEST=1` only; no-op otherwise. See
        // UITestSupport.swift.
        #if DEBUG
        await UITestBypass.seedFakeSessionIfNeeded(into: keychain)
        // Seed the entitlement cache to `.pro` BEFORE EntitlementService is
        // constructed below, so the Read Aloud Pro gate passes offline.
        UITestBypass.seedProEntitlementIfNeeded()
        #endif

        // 2. Token provider reads from the same keychain.
        let tokenProvider = RishiAuthTokenProvider(keychain: keychain)

        // 3. WorkerClient with dev-bypass gated to DEBUG only.
        #if DEBUG
        // In live-voice UITest mode force the bypass ON and attach the real
        // secret (forwarded from the test process), so the realtime
        // client-secret call authenticates as `dev-user` against the live
        // worker with no real session. Otherwise honor DevBypassConfig.
        let devBypassEnabled = UITestBypass.isLiveVoiceActive || DevBypassConfig.isEnabled
        let devBypassSecret: String? = UITestBypass.isLiveVoiceActive
            ? UITestBypass.devBypassSecret
            : nil
        #else
        let devBypassEnabled = false
        let devBypassSecret: String? = nil
        #endif
        let workerClient = WorkerClient(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            devBypassEnabled: devBypassEnabled,
            devBypassSecret: devBypassSecret
        )

        // 4-6. Auth presenter + coordinator + service. SystemSiwaPresenter
        // is `@MainActor` and we are NOT on main here. The presenter's
        // init is a cheap struct alloc with no UI calls; the actual
        // `present(...)` call happens later on MainActor when the user
        // taps Sign In. We hop onto MainActor just to construct it.
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

        // 7. Persistence — open the GRDB pool + run migrations. This is
        // the F-P0-04 hotspot: `RishiDB.makeDatabasePool` runs
        // `Migrations.migrator.migrate(pool)` inline. We are already off
        // the MainActor inside this `Task.detached` so the migration
        // runner does not block first-frame paint.
        //
        // `DatabasePool` (not `DatabaseQueue`) is the canonical GRDB shape
        // for this app: N concurrent reader connections + a single writer.
        // Library cover paint, position fan-out, multi-book queries can
        // now run `pool.read { ... }` in parallel from a `withTaskGroup`
        // without serialising on a single shared connection. Writes still
        // serialise — same semantics as before.
        //
        // Plan 19-08 F-P2-04 MEDIUM — race the DB open against the
        // AVAudioEngine alloc (Wave A). Both are independent of each
        // other and of `workerClient`; the slower of the two now bounds
        // the cold-launch ProgressView instead of their sum.
        let documentsURL = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first!
        let dbURL = documentsURL.appendingPathComponent("rishi.sqlite")

        // Wave A — independent heavy roots run as child tasks via
        // `async let`. The DB open (sync, GRDB pool + migrations) and
        // the AVAudioEngine alloc (MainActor hop + node setup) share no
        // dependency, so racing them lets the slower of the two bound
        // the cold-launch ProgressView. The other items in `build`
        // (auth coordinator, stores, uploaders, fetchers, view models) are
        // either microseconds of struct allocation OR depend on these two
        // outputs, so leaving them serial costs nothing measurable.
        async let dbWriterTask: any DatabaseWriter = Self.openDatabaseWriter(at: dbURL)
        async let audioStackTask: AudioStack = AudioStackFactory.make(workerClient: workerClient)

        let dbQueue = await dbWriterTask

        // 8. Stores.
        let bookStore = GRDBBookStore(dbQueue: dbQueue)
        let positionStore = GRDBPositionStore(dbQueue: dbQueue)
        let highlightStore = GRDBHighlightStore(dbQueue: dbQueue)
        let bookmarkStore = GRDBBookmarkStore(dbQueue: dbQueue)

        // 8b. Reader settings (per-book theme persistence via UserDefaults).
        let readerSettingsStore = UserDefaultsReaderSettingsStore()

        // 9. Library file storage (cover + metadata extractors for the two v1
        // formats). Metadata extractors populate `Book.title` / `Book.author`
        // from `<dc:title>` / `<dc:creator>` (EPUB) or PDFKit
        // `documentAttributes` (PDF); when they yield nothing the import path
        // falls back to a filename-derived title.
        //
        // Phase 25 Plan 25-11 — construct the RAG indexing hook BEFORE
        // BookFileStorage so every import schedules a detached background
        // HNSW + chunks.db build. Embedder construction CAN throw (Core ML
        // compile + model load on first launch); on failure we fall back to
        // `IdentityEmbedder` so the app stays up and the cold-start sentinel
        // covers the user-facing path. The embedder is NOT eagerly pre-warmed
        // — RESEARCH OQ-4 says prewarm runs inside
        // `RealtimeVoiceSession.start(bookId:)` only.
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
        // Phase 27-06: read the persisted "skip page footers when indexing"
        // toggle synchronously at hook construction time. Runtime toggle
        // changes do NOT retroactively reindex already-indexed books — new
        // imports get the new policy; old indices reflect the policy they
        // were built with until a fresh reindex.
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

        // 9b. Sync — composition root for the engine + background coordinator.
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
        // Phase 37-08 (BMK-05) — bookmark outbound uploader, mirroring the
        // highlight chain. `bookmarkStore` was built above (GRDBBookmarkStore).
        let bookmarkUploader = BookmarkUploader(
            workerClient: workerClient,
            bookmarkStore: bookmarkStore,
            metadataStore: syncMetadataStore
        )

        // Phase 16-04 — conversation + message GRDB stores must exist before
        // the SyncEngine so the new uploaders can be wired into the init.
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

        // BackgroundTaskCoordinator is @MainActor-isolated. Construct it
        // on main; the actual `register()` call from
        // `BackgroundSyncLifecycle.registerSynchronously()` happens later.
        let backgroundTaskCoordinator = await MainActor.run {
            BackgroundTaskCoordinator(engine: syncEngine)
        }
        let apnsDeviceRegistrar = APNsDeviceRegistrar(workerClient: workerClient)

        // 10. Import coordinator.
        //
        // Phase 21 Plan 21-05 — wire a second consumer onto the existing
        // onBookImported hook so that, in parallel with Phase 7's
        // SYNC-01 markBookDirty enqueue, the format-specific persistent
        // warm cache (PDFThumbnailCache page 0 / EPUBUnpackedCache
        // unpacked tree) gets populated the moment the book lands on
        // disk. The pre-warm runs fire-and-forget on
        // `Task.detached(priority: .userInitiated)` so it never blocks
        // the import flow or delays the LibraryViewModel.refresh()
        // that the picker / drop surface fires right after.
        //
        // Cache instances are shared with the cold-open path via the
        // EPUBPublicationLoader / PDFKit readers — both default to
        // `<systemCaches>/EPUBUnpacked` and `<systemCaches>/PDFThumbnails`
        // so the warm directories the prewarmer writes here are the
        // exact directories the readers consult on the next open.
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
                // Phase 7 SYNC-01 — enqueue the upload. Preserve this
                // call exactly: dropping it would silently regress sync.
                await syncEngine.markBookDirty(bookId)
                // Phase 21 Plan 21-05 — fire-and-forget pre-warm. We do
                // NOT await the detached task; the import flow returns
                // immediately and `LibraryViewModel.refresh()` runs
                // unblocked. Failures inside `prewarm` are silent by
                // contract — the cold-open path remains the fallback.
                // DETACHED: multi-step I/O (bookStore fetch + EPUB unzip
                // / PDF render); earns the detach per Pattern C (Rule 10
                // does NOT apply — body is two awaits + dispatch, not a
                // single actor-method await).
                Task.detached(priority: .userInitiated) {
                    guard let book = try? await bookStore.book(bookId) else { return }
                    let url = await bookFileStorage.absoluteFileURL(for: book)
                    await bookPrewarmer.prewarm(book: book, fileURL: url)
                }
            }
        )

        // 11. Sample-book installers (first-run alice.epub + sample.pdf).
        let sampleBookInstaller = SampleBookInstaller(storage: bookFileStorage)
        let sampleReaderInstaller = SampleReaderInstaller(storage: bookFileStorage)

        // 12. Bind the @Observable SyncStatus to the engine actor.
        // KEEP: fire-and-forget; syncEngine is an actor and `bind(status:)`
        // is a cheap field assignment behind the actor hop. No IO.
        Task { [syncEngine, syncStatus] in
            await syncEngine.bind(status: syncStatus)
        }

        // 14. Audio / TTS stack (Phase 8) — kicked off in Wave A above so
        // its AVAudioEngine alloc races the DB open. We harvest the
        // result here, where the first downstream consumer
        // (`voicePresenter`) actually needs it.
        let audioStack = await audioStackTask

        // 15. Chat stack (Phase 9).
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

        // 15b. Book-aware RAG stack (Phase 25 Plan 25-10 + 25-11).
        //
        // The shared `embedder` was constructed earlier (alongside the
        // BookFileStorage indexing-hook wiring) so import-time indexing and
        // query-time search share ONE Core ML model instance — keeps Core ML
        // compile cost at one-per-process. `USearchBookSearch` is the per-book
        // facade the voice path queries; cold-start sentinel kicks in when an
        // index isn't ready yet (mid-import).
        //
        // The embedder is NOT eagerly pre-warmed at app launch — RESEARCH OQ-4
        // says prewarm runs ONLY inside `RealtimeVoiceSession.start(bookId:)`,
        // so users who never use voice never pay the ~500 ms cold-load cost.
        let bookSearch = USearchBookSearch(
            rootURL: documentsURL,
            embedder: embedder,
            k: 3
        )
        let embedderForPrewarm = embedder
        let embedderPrewarm: @Sendable () async -> Void = {
            await embedderForPrewarm.prewarm()
        }

        // 16. Voice stack (Phase 10 Plan 10-06 / Phase 25 Plan 25-10).
        //
        // Under RISHI_UITEST we swap in offline fakes (client + key fetcher +
        // granted mic gate) so a voice session reaches `.live` with no worker,
        // no OpenAI, no WebRTC, and no system mic prompt — letting the
        // start->end->start reproduction UITest (VoiceRestartUITests) drive the
        // real presenter/session FSM deterministically. Production wiring is
        // untouched: the fakes are nil outside RISHI_UITEST (and the whole
        // UITestVoiceFakes file is `#if DEBUG`-gated), so the presenter falls
        // back to its production default constructions.
        let voicePresenter = await MainActor.run {
            #if DEBUG
            // LIVE-VOICE UITest (RISHI_UITEST_LIVE_VOICE=1) takes precedence
            // over the offline-fake branch: build the PRODUCTION voice path —
            // real RealtimeAPIAdapter + real EphemeralKeyFetcher hitting the
            // live worker/OpenAI (no clientFactory / keyFetcherFactory) AND the
            // REAL SystemMicPermissionGate (production default). The realtime
            // SDK hard-checks the OS-level `AVAudioApplication.recordPermission`
            // at connect; an always-granted app-level gate would NOT satisfy
            // it. Using the real gate makes `start()` actually request OS mic
            // permission, so on a physical device the system prompt fires and
            // the UITest auto-accepts it via a UIInterruptionMonitor (on a
            // simulator, pre-grant with `simctl privacy ... grant microphone`).
            if UITestBypass.isLiveVoiceActive {
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
            // Plain RISHI_UITEST (non-live): offline fakes — client + key
            // fetcher + granted mic gate — so the session reaches `.live`
            // with no network, no OpenAI, no WebRTC, no mic prompt.
            if UITestBypass.isActive {
                return VoiceSessionPresenter(
                    coordinator: audioStack.coordinator,
                    workerClient: workerClient,
                    messageStore: messageStore,
                    conversationLookup: conversationLookup,
                    userIdProvider: { [userIdBox] in userIdBox.value },
                    dirtyHook: voiceDirtyAdapter,
                    micGate: UITestGrantedMicGate(),
                    bookSearch: bookSearch,
                    embedderPrewarm: embedderPrewarm,
                    clientFactory: { UITestFakeRealtimeClient() },
                    keyFetcherFactory: { UITestFakeEphemeralKeyFetcher() }
                )
            }
            #endif
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

        // 17. Billing stack.
        let entitlementService = EntitlementService(workerClient: workerClient)
        let manageSubscriptionPresenter = await MainActor.run {
            ManageSubscriptionPresenter()
        }

        let storekitState = signposter.beginInterval("storekit.ready")
        let productService = StoreKitProductService()
        let receiptVerifier: any ReceiptVerifier = {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "RishiUseStubReceiptVerifier") {
                Log.event("iap.verifier.stub.enabled", level: .info)
                return DebugStubReceiptVerifier()
            }
            #endif
            return WorkerReceiptVerifier(client: workerClient)
        }()
        // Phase 36 — seed the reconciler SYNCHRONOUSLY from the hydrated
        // entitlement cache so a returning Pro / active-trial subscriber's
        // `reconciler.level` already reads `.pro` the first time `RootView`
        // (and `AppGate.resolve`) renders. Without this seed the reconciler
        // starts `.free` and only flips later via the async
        // `EntitlementServerBridge`, which races `authProbeComplete` and can
        // paint the full-screen paywall gate for a frame. The cache is
        // server-derived, so we feed the SERVER signal; the bridge then only
        // delivers subsequent updates.
        let cachedEntitlement = await entitlementService.snapshot()
        let reconciler = await MainActor.run {
            let reconciler = EntitlementReconciler()
            reconciler.setServer(cachedEntitlement)
            return reconciler
        }
        let purchaseService = PurchaseService(
            productFetcher: productService,
            verifier: receiptVerifier,
            reconciler: reconciler
        )
        let listener = TransactionListener(forwarder: purchaseService)
        let entitlementFlag = await MainActor.run {
            ReaderAppEntitlementFlag(reconciler: reconciler)
        }
        let restoreService = RestoreService(reconciler: reconciler)
        signposter.endInterval("storekit.ready", storekitState)

        // Launch hooks: replay any unfinished transactions FIRST.
        Task.detached(priority: .background) { [purchaseService, listener] in
            await purchaseService.replayUnfinished()
            await listener.start()
        }
        if StoreKitIAPFlag.isEnabled {
            Task.detached(priority: .background) { [productService] in
                _ = try? await productService.load()
            }
        }

        // 18. Settings stack.
        let telemetryStore = await MainActor.run {
            UserDefaultsTelemetryStore(sink: AppTelemetrySink())
        }

        // 19. Onboarding stack.
        let onboardingState = UserDefaultsOnboardingState()
        let onboardingCoordinator = await MainActor.run {
            OnboardingCoordinator(state: onboardingState)
        }

        // 20. Reader defaults.
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
            entitlementService: entitlementService,
            manageSubscriptionPresenter: manageSubscriptionPresenter,
            storeKitProductService: productService,
            purchaseService: purchaseService,
            transactionListener: listener,
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

    // MARK: - Wave A helpers (F-P2-04 medium)
    //
    // The parallelised cold-launch DB root called via `async let` from
    // `build`. `nonisolated` so the child task can begin work on its own
    // executor without bouncing to MainActor for the heavy phase. (The
    // audio root lives in `AudioStackFactory.make`.)

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
