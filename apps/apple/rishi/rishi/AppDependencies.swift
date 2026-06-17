import Foundation
import Observation
import OSLog
import SwiftUI
import RishiCore
import RishiAPI
import RishiAuth
import RishiAudio
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
#if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
import BackgroundTasks
#endif

/// Composition root for the rishi app. Constructed once by `rishiApp.init()`.
///
/// Phase 19 plan 19-01 — **two-phase bootstrap**.
///
/// ## Phase 1 — synchronous `init()`
/// The synchronous initializer is now empty by design. It returns in well
/// under 10ms because it allocates no DB queues, no AVAudioEngine, no
/// StoreKit object graph. `rishiApp.body` and the AppDelegate's
/// `didFinishLaunchingWithOptions` callback both run inside this cheap
/// window so first-frame paint is never blocked.
///
/// ## Phase 2 — async ``bootstrap()``
/// All heavy wiring (open the GRDB queue + run schema migrations, build
/// the audio stack, instantiate the StoreKit object graph) lives in
/// ``bootstrap()`` which trampolines into a `Task.detached(priority:
/// .userInitiated)` so the work happens off the MainActor. RootView gates
/// its `realBody` behind `deps.services != nil` and shows a `ProgressView`
/// until the factory completes.
///
/// ## BGTaskScheduler contract
/// Apple requires `BGTaskScheduler.register(...)` to be called before
/// `application(_:didFinishLaunchingWithOptions:)` returns. We honour that
/// by registering the launch handlers directly against `BGTaskScheduler`
/// in ``registerBGTasksSynchronously()`` — that helper runs at the very
/// top of the AppDelegate's `didFinishLaunching`, BEFORE bootstrap. The
/// handlers capture `self` weakly and short-circuit to
/// `task.setTaskCompleted(success: false)` when ``services`` is still nil
/// (i.e. the OS fires a BG task before bootstrap has completed).
///
/// ## Force-unwrap accessors
/// To keep the 50+ existing `deps.bookStore`, `deps.syncEngine`, …
/// call-sites compiling untouched, every service field is exposed as a
/// computed property forwarding through `services!`. The outer
/// `if deps.services != nil` gate in `RootView.body` guarantees the
/// force-unwrap can never trip from a UI rendering path.
///
/// ## `@Observable` rationale
/// The class is `@Observable` so SwiftUI re-renders `RootView.body` when
/// ``bootstrap()`` flips ``services`` from `nil` to the populated
/// graph. The plan's docstring claimed `@State`-held reference tracking
/// would cover this — it does not, because `@State<AppDependencies>`
/// only observes replacement of the reference, not interior mutations.
/// Without `@Observable`, the `if deps.services != nil` gate would
/// latch on the initial `nil` read and never swap to `realBody`.
@MainActor
@Observable
final class AppDependencies {

    // MARK: - Two-phase bootstrap state

    /// Heavy service graph. `nil` until ``bootstrap()`` completes. The
    /// `private(set)` makes the assignment a single MainActor mutation
    /// from within ``bootstrap()`` itself — SwiftUI observes it via the
    /// `if deps.services != nil` guard in `RootView.body`.
    private(set) var services: BootstrappedServices?

    /// In-flight bootstrap task. Reentrant calls to ``bootstrap()`` join
    /// the same `Task` so a re-render of `RootView`'s `.task` modifier
    /// does not kick off a second detached DB-open.
    private var bootstrapTask: Task<Void, Never>?

    /// Signposter for the cold-launch trace. The top-level interval is
    /// `cold-launch.bootstrap` (Plan 19-08 — F-P2-04); inner boundaries
    /// `db.open`, `audio.ready`, `storekit.ready` are emitted as nested
    /// intervals so the Instruments Time Profiler attributes time to each
    /// hotspot inside the bootstrap. Plan 19-08 wires the other four hot
    /// paths (library / reader / chrome / sync) onto their own signposters.
    ///
    /// `nonisolated` so the off-main `makeServices()` factory can begin /
    /// end intervals without hopping back to MainActor (the enclosing
    /// class is `@MainActor`-isolated). OSSignposter itself is `Sendable`
    /// (Swift 6) so this is safe. Phase 19 Plan 19-06 fix — Rule 3.
    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

    // MARK: - Persistent UI-layer fields
    //
    // These do NOT depend on the heavy services and are safe to construct
    // synchronously. `macCommandRouter` is referenced from
    // `rishiApp.commands { ... }` BEFORE bootstrap completes (the menu bar
    // builds in the scene-init window) so it MUST stay on AppDependencies.

    /// MAC-03 / MAC-04 — single router brokering menu-bar commands and
    /// ⌘-key shortcuts to `RootView`. Lives at the composition root so the
    /// same instance is reachable from `WindowGroup.commands { ... }` AND
    /// from the SwiftUI environment that `RootView` reads.
    let macCommandRouter = MacCommandRouter()

    /// App-level source for the Mac menu-bar Account submenu. Lives here (like
    /// `macCommandRouter`) so `WindowGroup.commands` reads a focus-independent
    /// instance — the Account submenu must not depend on scene focus.
    let macAccountMenu = MacAccountMenuModel()

    /// Cached user id pumped in by SignedInView after the auth session resolves.
    /// `RishiChatService` and the voice presenter read this synchronously from
    /// their `currentUserId` closures so they do not need to hop into the auth actor.
    var cachedUserId: UserID? {
        get { userIdBox.value }
        set { userIdBox.value = newValue }
    }

    /// Heap-allocated reference box so the `RishiChatService` + voice presenter
    /// closures can capture a stable seam before `self` is fully wired.
    private let userIdBox = UserIdBox()

    // MARK: - Init (synchronous, cheap, no IO)

    /// `nonisolated` so SwiftUI's `@State private var deps = AppDependencies()`
    /// can construct the instance from the struct-level property initializer,
    /// which the compiler does not prove is on the MainActor even though the
    /// enclosing `App` body is. Body intentionally empty — all heavy work is
    /// moved to ``bootstrap()`` so there is nothing here that needs main.
    nonisolated init() {
        // Plan 19-01 must-have: this initializer returns in under 10ms.

        // DEBUG-simulator-only file-based log sink. Mirrors every structured
        // log event into reset-on-launch dump files inside the simulator's
        // app sandbox so the host (Claude Code orchestrator) can read them
        // from the Mac via `xcrun simctl get_app_container booted
        // org.fidexa.rishi data` when triaging a bug report. Returns nil
        // (no-op) on device or in Release; safe to call unconditionally.
        // See `apps/apple/scripts/rishi-dump-path.sh` for the host script.
        #if DEBUG && targetEnvironment(simulator)
        if let dumpSink = SimulatorDumpSink.make() {
            Log.installSink(dumpSink)
        }
        #endif
    }

    // MARK: - Bootstrap (off-main)

    /// Build the heavy service graph off the MainActor and publish it via
    /// ``services``. SwiftUI's `RootView.body` re-renders when `services`
    /// flips non-nil because the `private(set) var` lives on a
    /// `@MainActor`-isolated class held by `@State`.
    ///
    /// Re-entrant: a second concurrent call joins the in-flight task.
    func bootstrap() async {
        if let inFlight = bootstrapTask {
            await inFlight.value
            return
        }
        // KEEP: outer Task here is a *handle* for re-entry coalescing —
        // multiple concurrent bootstrap() callers join the same in-flight
        // task. The real off-main work lives inside makeServices(...),
        // which is `static nonisolated` and wraps its body in
        // Task.detached(priority: .userInitiated) — see plan 19-01.
        let task = Task { [weak self] in
            guard let self else { return }
            let signpostId = Self.signposter.makeSignpostID()
            let state = Self.signposter.beginInterval("cold-launch.bootstrap", id: signpostId)
            let built = await Self.makeServices(userIdBox: self.userIdBox)
            self.services = built
            Self.signposter.endInterval("cold-launch.bootstrap", state)
        }
        bootstrapTask = task
        await task.value
    }

    /// Off-main factory. `nonisolated` static + wrapped in `Task.detached`
    /// so the entire heavy graph constructs without bouncing onto the
    /// MainActor. The Swift Programming Language book covers this pattern
    /// under "Tasks and Task Groups → Unstructured Concurrency"
    /// (`Task.detached` opts out of the surrounding actor isolation) and
    /// "Isolation → Nonisolated Code" (`nonisolated` static methods on a
    /// `@MainActor` class are allowed).
    nonisolated private static func makeServices(
        userIdBox: UserIdBox
    ) async -> BootstrappedServices {
        await Task.detached(priority: .userInitiated) {
            await buildServices(userIdBox: userIdBox)
        }.value
    }

    /// Off-main service-graph builder. Invoked from inside `Task.detached`
    /// (off-main) by ``makeServices(userIdBox:)``. Hops onto MainActor
    /// only for the small subset of objects whose initialisers are
    /// MainActor-isolated upstream (SwiftUI presenters, `@Observable`
    /// view models, `BackgroundTaskCoordinator`). The bulk of the work —
    /// GRDB queue open + migrations, AVAudioEngine alloc, StoreKit graph
    /// — runs nonisolated on the detached executor.
    nonisolated private static func buildServices(
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
        // the cold-launch ProgressView. The other items in `buildServices`
        // (auth coordinator, stores, uploaders, fetchers, view models) are
        // either microseconds of struct allocation OR depend on these two
        // outputs, so leaving them serial costs nothing measurable.
        async let dbWriterTask: any DatabaseWriter = Self.openDatabaseWriter(at: dbURL)
        async let audioStackTask: AudioStack = Self.openAudioStack(workerClient: workerClient)

        let dbQueue = await dbWriterTask

        // 8. Stores.
        let bookStore = GRDBBookStore(dbQueue: dbQueue)
        let positionStore = GRDBPositionStore(dbQueue: dbQueue)
        let highlightStore = GRDBHighlightStore(dbQueue: dbQueue)

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
            fileStorage: bookFileStorage
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
        // `registerBGTasksSynchronously()` happens later.
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
        let purchaseService = PurchaseService(
            productFetcher: productService,
            verifier: receiptVerifier
        )
        let listener = TransactionListener(forwarder: purchaseService)
        let reconciler = await MainActor.run { EntitlementReconciler() }
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

    // MARK: - BGTask registration (synchronous; honours Apple ordering contract)

    /// Register BGTask launch handlers BEFORE
    /// `application(_:didFinishLaunchingWithOptions:)` returns. Apple's
    /// `BGTaskScheduler` documentation requires registration to happen
    /// inside the launch window; if bootstrap has not yet completed (the
    /// expected case), the handlers short-circuit to
    /// `task.setTaskCompleted(success: false)` so the OS reschedules the
    /// task for a later wave.
    ///
    /// Called from `RishiAppDelegate.application(_:didFinishLaunching:)`.
    /// The handlers themselves are `@MainActor` per the
    /// `BGTaskScheduler.register(forTaskWithIdentifier:using:)` contract.
    @MainActor
    func registerBGTasksSynchronously() {
        #if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
        let processing = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.processingIdentifier,
            using: nil
        ) { [weak self] task in
            // KEEP: BGTaskScheduler hands the BGTask to MainActor by
            // contract; driveBGTask awaits the syncEngine actor on its
            // own executor. Body chains an await — no main-bound IO.
            Task { @MainActor in
                await self?.driveBGTask(task)
            }
        }
        let refresh = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.refreshIdentifier,
            using: nil
        ) { [weak self] task in
            // KEEP: same shape as the processing variant above.
            Task { @MainActor in
                await self?.driveBGTask(task)
            }
        }
        Log.event("sync.bg.registered", level: .info, data: [
            "processing": String(processing),
            "refresh": String(refresh),
            "via": "AppDependencies.registerBGTasksSynchronously",
        ])

        // Submit the initial BG task requests. `BGTaskScheduler.submit` is
        // safe to call any time after `register`. Launch handlers re-arm
        // on every completion via `BackgroundTaskCoordinator.scheduleAll()`
        // after bootstrap publishes the coordinator.
        do {
            let processingRequest = BGProcessingTaskRequest(
                identifier: BackgroundTaskCoordinator.processingIdentifier
            )
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false
            try BGTaskScheduler.shared.submit(processingRequest)

            let refreshRequest = BGAppRefreshTaskRequest(
                identifier: BackgroundTaskCoordinator.refreshIdentifier
            )
            refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
            try BGTaskScheduler.shared.submit(refreshRequest)
            Log.event("sync.bg.scheduled", level: .info)
        } catch {
            Log.error("sync.bg.schedule.failed", error: error)
        }
        #endif
    }

    #if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
    /// Common BGTask drive path used by both the processing and refresh
    /// launch handlers registered above. Bootstrap must be complete
    /// before we can drive `syncEngine.runOnce()`; if the OS fires before
    /// bootstrap finishes we await it (it'll be in-flight from
    /// `rishiApp.body`'s `.task` already). After bootstrap completes,
    /// `BackgroundTaskCoordinator.scheduleAll()` re-arms the next wave.
    @MainActor
    private func driveBGTask(_ task: BGTask) async {
        // Ensure bootstrap has completed (or in-flight bootstrap completes
        // before we run). If the in-flight task is nil at OS BG fire time,
        // start one — production launch ALWAYS kicks bootstrap from
        // `rishiApp.body`'s `.task` so this is purely a safety net.
        if services == nil {
            await bootstrap()
        }
        guard let services else {
            task.setTaskCompleted(success: false)
            return
        }
        // Phase 33 plan 33-02 — Auto Sync gate (§G2 site 1). When the user
        // turns Auto Sync OFF, the OS-scheduled background wave is a no-op:
        // report success (the task DID its job — "nothing to do") AND re-arm
        // via scheduleAll() so the budget survives for when the flag flips
        // back on. Manual `syncNow()` is never gated — the gate lives here at
        // the auto call site, not inside SyncEngine.
        guard services.readerDefaults.autoSync else {
            task.setTaskCompleted(success: true)
            services.backgroundTaskCoordinator.scheduleAll()
            return
        }
        // KEEP: runTask handle is consumed by `task.expirationHandler` for
        // cancellation; the engine.runOnce() body runs on the syncEngine
        // actor's executor. Wrapper body only chains an await + returns Bool.
        let runTask = Task { [engine = services.syncEngine] in
            let wave = await engine.runOnce()
            return wave.errors.isEmpty
        }
        task.expirationHandler = { runTask.cancel() }
        let ok = (try? await runTask.value) ?? false
        task.setTaskCompleted(success: ok)
        services.backgroundTaskCoordinator.scheduleAll()
    }
    #endif

    // MARK: - Audio stack (Phase 8)

    /// Bundle of audio services constructed together so the init body stays
    /// readable. Computed in a static helper because init can't reference
    /// `self` partway through property assignments.
    // `@unchecked Sendable` so this can flow back as the result of an
    // `async let` child task in `buildServices` Wave A (the audio stack
    // and the DB pool race each other off-main). The contained types are
    // reference types already used across actor boundaries downstream;
    // bundling them in this struct doesn't change those invariants.
    fileprivate struct AudioStack: @unchecked Sendable {
        let coordinator: AudioSessionCoordinator
        let state: TTSPlaybackState
        let engine: TTSEngine
        let settingsStore: any TTSSettingsStore
        let nowPlaying: NowPlayingController
        // Phase 24 plan 24-03 — prewarmer for paragraph read-ahead. Built
        // from the SAME `chunkSource` the engine streams from so warm
        // drains hit the same CachingTTSChunkSource the engine consults.
        let prewarmer: TTSPrewarmer
    }

    // MARK: - Wave A helpers (F-P2-04 medium)
    //
    // These two helpers are the parallelised cold-launch roots called
    // via `async let` from `buildServices`. They are `nonisolated` so the
    // child task can begin work on its own executor without bouncing to
    // MainActor for the heavy phase.

    nonisolated internal static func openDatabaseWriter(
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

    nonisolated fileprivate static func openAudioStack(
        workerClient: WorkerClient
    ) async -> AudioStack {
        let audioState = signposter.beginInterval("audio.ready")
        defer { signposter.endInterval("audio.ready", audioState) }
        return await MainActor.run {
            Self.makeAudioStack(workerClient: workerClient)
        }
    }

    @MainActor
    fileprivate static func makeAudioStack(workerClient: WorkerClient) -> AudioStack {
        #if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(AVFAudio)
        let configurator: any AudioSessionConfigurator = AVAudioSessionConfigurator()
        #else
        let configurator: any AudioSessionConfigurator = FakeAudioSessionConfigurator()
        #endif

        #if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(MediaPlayer)
        let infoSurface: any NowPlayingInfoSurface = MPNowPlayingInfoCenterAdapter()
        let commandSurface: any RemoteCommandSurface = MPRemoteCommandCenterAdapter()
        #else
        let infoSurface: any NowPlayingInfoSurface = FakeNowPlayingInfoSurface()
        let commandSurface: any RemoteCommandSurface = FakeRemoteCommandSurface()
        #endif

        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let state = TTSPlaybackState()
        // Phase 22 plan 22-03 — wrap the production WorkerTTSChunkSource in
        // a CachingTTSChunkSource so repeat plays of the same (text, voice,
        // speed) on this device round-trip from local disk with zero network
        // and zero OpenAI cost. If the cache store init throws (e.g. caches
        // directory cannot be created), fall back to the bare upstream so a
        // broken cache never breaks TTS. The downstream
        // `TTSStreamer(source:)` keeps consuming `any TTSChunkSource`, so
        // the streamer + engine + lock-screen surface need no edit.
        let ttsUpstream = WorkerTTSChunkSource(client: workerClient)
        let ttsCacheStore: TTSAudioCacheStore?
        do {
            ttsCacheStore = try TTSAudioCacheStore()
        } catch {
            Log.event("tts.cache.init.failed", level: .error, data: ["error": "\(error)"])
            ttsCacheStore = nil
        }
        var chunkSource: any TTSChunkSource = ttsCacheStore.map { store in
            CachingTTSChunkSource(upstream: ttsUpstream, store: store)
        } ?? ttsUpstream
        // UITEST — swap in a deterministic, fixture-backed offline source so
        // Read Aloud renders real audio through the production AVAudioEngine
        // with no worker round-trip and no auth. DEBUG + `RISHI_UITEST=1`
        // only. See UITestSupport.swift.
        #if DEBUG
        if UITestBypass.isActive {
            if UITestBypass.latentCachedTTS,
               let store = try? TTSAudioCacheStore(
                   directory: FileManager.default.temporaryDirectory
                       .appendingPathComponent("uitest-tts-\(UUID().uuidString)", isDirectory: true)
               ) {
                // Faithful repro of the production path: a latent fixture
                // (simulated synthesis delay) behind a real cache, with a fresh
                // per-launch cache dir so each paragraph's first play actually
                // "synthesizes". Reproduces prewarm-vs-Next timing.
                chunkSource = CachingTTSChunkSource(
                    upstream: FixtureTTSChunkSource(synthDelay: UITestBypass.ttsSynthDelay),
                    store: store
                )
                Log.event("uitest.tts.source.latent_cached", level: .info)
            } else {
                chunkSource = FixtureTTSChunkSource()
                Log.event("uitest.tts.source.swapped", level: .info)
            }
        }
        #endif
        // Phase 24 plan 24-03 — prewarm next 3-5 paragraphs through the
        // same CachingTTSChunkSource the engine streams from. A miss
        // writes the MP3 to disk; a hit is a no-op. ReaderTTSBridge owns
        // the lockstep.
        let prewarmer = TTSPrewarmer(source: chunkSource)
        let streamer = TTSStreamer(source: chunkSource)
        let engineAdapter = AVAudioEngineAdapter()
        let engine = TTSEngine(
            streamer: streamer,
            decoderFactory: { try MP3StreamDecoder(targetFormat: $0) },
            engine: engineAdapter,
            coordinator: coordinator,
            state: state
        )
        let settingsStore = UserDefaultsTTSSettingsStore()
        let nowPlaying = NowPlayingController(
            infoSurface: infoSurface,
            commandSurface: commandSurface
        )
        return AudioStack(
            coordinator: coordinator,
            state: state,
            engine: engine,
            settingsStore: settingsStore,
            nowPlaying: nowPlaying,
            prewarmer: prewarmer
        )
    }

}

// MARK: - BootstrappedServices

/// Heavy service graph built off-main by ``AppDependencies/bootstrap()``.
///
/// Holds references to every long-lived service. `Sendable`-by-construction
/// because every member is an actor, a `Sendable` reference type, or a
/// value type composed of `Sendable` parts. `@unchecked` is used because
/// the SwiftUI / UIKit reference types (presenters, view models) carry no
/// `Sendable` annotation upstream — we hop onto MainActor when constructing
/// them inside ``AppDependencies/buildServices(userIdBox:)`` and they stay
/// pinned to MainActor for their lifetimes.
struct BootstrappedServices: @unchecked Sendable {
    // Auth + transport
    let keychain: KeychainSessionStore
    let tokenProvider: RishiAuthTokenProvider
    let workerClient: WorkerClient
    let siwaPresenter: SystemSiwaPresenter
    let siwaCoordinator: SignInWithAppleCoordinator
    let authService: RishiAuthService

    // Persistence + library
    let dbQueue: any DatabaseWriter
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let highlightStore: any HighlightStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let readerSettingsStore: any ReaderSettingsStore

    // Audio / TTS
    let audioCoordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: TTSEngine
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController
    let ttsPrewarmer: TTSPrewarmer

    // Sync
    let syncMetadataStore: GRDBSyncMetadataStore
    let syncQueue: SyncQueue
    let syncStatus: SyncStatus
    let bookUploader: BookUploader
    let positionUploader: PositionUploader
    let highlightUploader: HighlightUploader
    let remoteChangeFetcher: RemoteChangeFetcher
    let changeApplier: ChangeApplier
    let syncEngine: SyncEngine
    let backgroundTaskCoordinator: BackgroundTaskCoordinator
    let apnsDeviceRegistrar: APNsDeviceRegistrar
    let chatRefreshAdapter: AppChatRefreshAdapter

    // Chat
    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let conversationLookup: ConversationLookup
    let voiceDirtyAdapter: AppVoiceDirtyAdapter
    let chatService: RishiChatService

    // Voice
    let voicePresenter: VoiceSessionPresenter

    // RAG (on-device semantic index)
    /// Per-book semantic search facade. Exposed so reader destinations can
    /// query `status(bookId:)` for the indexing chip and the open-time
    /// backfill decision (`shouldBackfillIndex`).
    let bookSearch: any BookSearch
    /// Background index builder. Exposed so reader destinations can backfill
    /// the RAG index for books imported before indexing existed.
    let indexingHook: any BookIndexingHook

    // Billing
    let entitlementService: EntitlementService
    let manageSubscriptionPresenter: ManageSubscriptionPresenter
    let storeKitProductService: StoreKitProductService
    let purchaseService: PurchaseService
    let transactionListener: TransactionListener
    let entitlementReconciler: EntitlementReconciler
    let readerAppEntitlementFlag: ReaderAppEntitlementFlag
    let restoreService: RestoreService
    let workerReceiptVerifier: any ReceiptVerifier

    // Settings + onboarding
    let telemetryStore: any TelemetryStore
    /// Phase 27-06 — persisted toggle store for the "Skip page footers when
    /// indexing" setting. Read by `SettingsSheet` to bind the UI; the
    /// PdfTextExtractor reads its value SYNCHRONOUSLY at hook-construction
    /// time (see Phase 27-06 wire-up note), so runtime toggle changes do
    /// not retroactively reindex.
    let footerDetectionStore: any FooterDetectionStore
    let onboardingState: any OnboardingState
    let onboardingCoordinator: OnboardingCoordinator
    let readerDefaults: AppReaderDefaults
}

/// Tiny @MainActor-isolated reference box so `RishiChatService` and the voice
/// presenter's `currentUserId` closures can be constructed before `self` is
/// fully initialised. The closures capture the box (a reference type),
/// AppDependencies mutates `box.value`, and consumers read the latest value
/// on every `currentUserId()` call.
@MainActor
final class UserIdBox {
    var value: UserID? = nil

    /// Mirror the `nonisolated init()` on `AppDependencies` so the
    /// composition root's `let userIdBox = UserIdBox()` property
    /// initializer is callable from `AppDependencies`' nonisolated init.
    nonisolated init() {}
}

// MARK: - SwiftUI environment keys

private struct RishiAuthServiceKey: EnvironmentKey {
    static let defaultValue: (any AuthService)? = nil
}

extension EnvironmentValues {
    var rishiAuthService: (any AuthService)? {
        get { self[RishiAuthServiceKey.self] }
        set { self[RishiAuthServiceKey.self] = newValue }
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    @MainActor static let defaultValue: AppDependencies? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}

// MARK: - Feature flags (Phase 8)

/// Compile-time feature flags. Phase 8 ships Read Aloud behind a flag that
/// is ON in DEBUG (TestFlight + dev) and OFF in Release (App Store builds)
/// until UAT confirms the read-aloud pipeline meets quality bar.
enum FeatureFlags {
    /// TTS / Read Aloud surfaces (reader toolbar button, controls sheet,
    /// voice + speed picker). Gated to DEBUG until Phase 8 UAT closes.
    static var readAloud: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
