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

    /// Cached user id pumped in by RootView after the auth session resolves.
    /// LibraryViewModel reads this synchronously from its currentUserId
    /// closure so refresh() does not need to hop into the auth actor.
    var cachedUserId: UserID? {
        get { userIdBox.value }
        set { userIdBox.value = newValue }
    }

    /// Heap-allocated reference box so the LibraryViewModel + ChatService
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

        // 2. Token provider reads from the same keychain.
        let tokenProvider = RishiAuthTokenProvider(keychain: keychain)

        // 3. WorkerClient with dev-bypass gated to DEBUG only.
        #if DEBUG
        let devBypassEnabled = DevBypassConfig.isEnabled
        #else
        let devBypassEnabled = false
        #endif
        let workerClient = WorkerClient(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            devBypassEnabled: devBypassEnabled
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
            ]
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
        let importCoordinator = ImportCoordinator(
            storage: bookFileStorage,
            currentUserId: {
                await authService.currentUser?.id
            },
            onBookImported: { [syncEngine] bookId in
                await syncEngine.markBookDirty(bookId)
            }
        )

        // 11. Sample-book installers (first-run alice.epub + sample.pdf).
        let sampleBookInstaller = SampleBookInstaller(storage: bookFileStorage)
        let sampleReaderInstaller = SampleReaderInstaller(storage: bookFileStorage)

        // 12. Library view model — needs MainActor isolation.
        let libraryViewModel = await MainActor.run {
            LibraryViewModel(
                bookStore: bookStore,
                positionStore: positionStore,
                storage: bookFileStorage,
                currentUserId: { userIdBox.value }
            )
        }

        // 13. Bind the @Observable SyncStatus to the engine actor.
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
        let chatPresenter = await MainActor.run { ChatPresenterImpl() }

        // 16. Voice stack (Phase 10 Plan 10-06).
        let voicePresenter = await MainActor.run {
            VoiceSessionPresenter(
                coordinator: audioStack.coordinator,
                workerClient: workerClient,
                messageStore: messageStore,
                conversationLookup: conversationLookup,
                userIdProvider: { [userIdBox] in userIdBox.value },
                dirtyHook: voiceDirtyAdapter
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
            libraryViewModel: libraryViewModel,
            readerSettingsStore: readerSettingsStore,
            audioCoordinator: audioStack.coordinator,
            ttsState: audioStack.state,
            ttsEngine: audioStack.engine,
            ttsSettingsStore: audioStack.settingsStore,
            nowPlayingController: audioStack.nowPlaying,
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
            chatPresenter: chatPresenter,
            voicePresenter: voicePresenter,
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

    // MARK: - Forwarder accessors (compat with pre-bootstrap call sites)
    //
    // These force-unwrap `services` and are ONLY safe to read AFTER
    // `RootView.body` confirms `deps.services != nil`. The 50+ existing
    // call sites in RootView/SettingsSheet/OnboardingHost reach into the
    // composition root through these accessors; the outer gate guarantees
    // the unwrap never traps from a UI rendering path.

    var keychain: KeychainSessionStore { services!.keychain }
    var tokenProvider: RishiAuthTokenProvider { services!.tokenProvider }
    var workerClient: WorkerClient { services!.workerClient }
    var siwaPresenter: SystemSiwaPresenter { services!.siwaPresenter }
    var siwaCoordinator: SignInWithAppleCoordinator { services!.siwaCoordinator }
    var authService: RishiAuthService { services!.authService }

    var dbQueue: any DatabaseWriter { services!.dbQueue }
    var bookStore: any BookStore { services!.bookStore }
    var positionStore: any PositionStore { services!.positionStore }
    var highlightStore: any HighlightStore { services!.highlightStore }
    var bookFileStorage: BookFileStorage { services!.bookFileStorage }
    var importCoordinator: ImportCoordinator { services!.importCoordinator }
    var sampleBookInstaller: SampleBookInstaller { services!.sampleBookInstaller }
    var sampleReaderInstaller: SampleReaderInstaller { services!.sampleReaderInstaller }
    var libraryViewModel: LibraryViewModel { services!.libraryViewModel }
    var readerSettingsStore: any ReaderSettingsStore { services!.readerSettingsStore }

    var audioCoordinator: AudioSessionCoordinator { services!.audioCoordinator }
    var ttsState: TTSPlaybackState { services!.ttsState }
    var ttsEngine: TTSEngine { services!.ttsEngine }
    var ttsSettingsStore: any TTSSettingsStore { services!.ttsSettingsStore }
    var nowPlayingController: NowPlayingController { services!.nowPlayingController }

    var syncMetadataStore: GRDBSyncMetadataStore { services!.syncMetadataStore }
    var syncQueue: SyncQueue { services!.syncQueue }
    var syncStatus: SyncStatus { services!.syncStatus }
    var bookUploader: BookUploader { services!.bookUploader }
    var positionUploader: PositionUploader { services!.positionUploader }
    var highlightUploader: HighlightUploader { services!.highlightUploader }
    var remoteChangeFetcher: RemoteChangeFetcher { services!.remoteChangeFetcher }
    var changeApplier: ChangeApplier { services!.changeApplier }
    var syncEngine: SyncEngine { services!.syncEngine }
    var backgroundTaskCoordinator: BackgroundTaskCoordinator { services!.backgroundTaskCoordinator }
    var apnsDeviceRegistrar: APNsDeviceRegistrar { services!.apnsDeviceRegistrar }
    var chatRefreshAdapter: AppChatRefreshAdapter { services!.chatRefreshAdapter }

    var conversationStore: any ConversationStore { services!.conversationStore }
    var messageStore: any MessageStore { services!.messageStore }
    var conversationLookup: ConversationLookup { services!.conversationLookup }
    var voiceDirtyAdapter: AppVoiceDirtyAdapter { services!.voiceDirtyAdapter }
    var chatService: RishiChatService { services!.chatService }
    var chatPresenter: ChatPresenterImpl { services!.chatPresenter }
    var voicePresenter: VoiceSessionPresenter { services!.voicePresenter }

    var entitlementService: EntitlementService { services!.entitlementService }
    var manageSubscriptionPresenter: ManageSubscriptionPresenter { services!.manageSubscriptionPresenter }
    var storeKitProductService: StoreKitProductService { services!.storeKitProductService }
    var purchaseService: PurchaseService { services!.purchaseService }
    var transactionListener: TransactionListener { services!.transactionListener }
    var entitlementReconciler: EntitlementReconciler { services!.entitlementReconciler }
    var readerAppEntitlementFlag: ReaderAppEntitlementFlag { services!.readerAppEntitlementFlag }
    var restoreService: RestoreService { services!.restoreService }
    var workerReceiptVerifier: any ReceiptVerifier { services!.workerReceiptVerifier }
    var telemetryStore: any TelemetryStore { services!.telemetryStore }
    var onboardingState: any OnboardingState { services!.onboardingState }
    var onboardingCoordinator: OnboardingCoordinator { services!.onboardingCoordinator }
    var readerDefaults: AppReaderDefaults { services!.readerDefaults }

    var authServiceForEnvironment: any AuthService { services!.authService }

    // MARK: - Paywall factory (Phase 13 plan 13-05)

    /// Build a fresh `PaywallViewModel` wired to the full IAP graph.
    @MainActor
    func makePaywallViewModel() -> PaywallViewModel {
        PaywallViewModel(
            productService: storeKitProductService,
            purchaseService: purchaseService,
            restoreService: restoreService,
            managePresenter: manageSubscriptionPresenter
        )
    }

    // MARK: - Chat factories (Phase 9)

    /// Builds a ``ChatPanelViewModel`` for a `(userId, bookId)` pair by
    /// resolving (or minting) the backing ``Conversation`` via
    /// ``ConversationLookup``.
    func makeChatPanelViewModel(
        userId: UserID,
        bookId: BookID?
    ) async -> ChatPanelViewModel? {
        do {
            let convo = try await conversationLookup.findOrCreate(
                userId: userId,
                bookId: bookId
            )
            return ChatPanelViewModel(
                conversation: convo,
                bookId: bookId,
                chatService: chatService,
                messageStore: messageStore
            )
        } catch {
            return nil
        }
    }

    /// Builds a ``ChatPanelViewModel`` for a conversation chosen from the
    /// Conversations tab.
    func makeChatPanelViewModel(conversation: Conversation) -> ChatPanelViewModel {
        ChatPanelViewModel(
            conversation: conversation,
            bookId: conversation.bookId,
            chatService: chatService,
            messageStore: messageStore
        )
    }

    /// Builds a fresh ``ConversationsListViewModel`` for the Conversations
    /// tab.
    func makeConversationsListViewModel() -> ConversationsListViewModel {
        ConversationsListViewModel(
            conversationStore: conversationStore,
            messageStore: messageStore
        )
    }

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
        let chunkSource = WorkerTTSChunkSource(client: workerClient)
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
            nowPlaying: nowPlaying
        )
    }

    /// Construct a fresh `ReaderTTSBridge` for one reader sheet.
    @MainActor
    func makeReaderTTSBridge(
        userId: UserID,
        onPassageChange: @escaping (Int?) -> Void
    ) -> ReaderTTSBridge {
        let tracker = TTSPassageTracker()
        return ReaderTTSBridge(
            engine: ttsEngine,
            state: ttsState,
            tracker: tracker,
            settingsStore: ttsSettingsStore,
            userId: userId,
            onPassageChange: onPassageChange
        )
    }

    // MARK: - Settings factory (Phase 11)

    /// Builds the `RishiSettings.SettingsScreen` for the current user,
    /// wiring every dependency through.
    @MainActor
    func makeSettingsScreen(
        user: User,
        audioInitial: TTSSettings,
        onDismiss: @escaping () -> Void,
        onSignedOut: @escaping () -> Void,
        onAccountDeleted: @escaping () -> Void
    ) -> SettingsScreen {
        let defaults = self.readerDefaults
        let auth = self.authService
        let presenter = self.manageSubscriptionPresenter
        let sync = self.syncEngine
        return SettingsScreen(
            user: user,
            readerTheme: Binding(
                get: { defaults.theme },
                set: { defaults.theme = $0 }
            ),
            readerFontFamily: Binding(
                get: { defaults.fontFamily },
                set: { defaults.fontFamily = $0 }
            ),
            audioUserId: user.id,
            audioInitial: audioInitial,
            audioStore: ttsSettingsStore,
            onAudioChange: { _ in },
            syncStatus: syncStatus,
            // KEEP: Settings "Sync now" tap → syncEngine actor await; no main IO.
            onSyncNow: { Task { await sync.syncNow() } },
            telemetryStore: telemetryStore,
            onSignOut: {
                try? await auth.signOut()
                await MainActor.run { onSignedOut() }
            },
            onDelete: {
                try await auth.deleteAccount()
            },
            onDeleted: onAccountDeleted,
            onManageSubscription: {
                // KEEP: presenter.present() drives StoreKit's
                // ManageSubscriptionsView which is a @MainActor sheet —
                // explicit isolation is required for the SwiftUI surface.
                Task { @MainActor in
                    await presenter.present()
                }
            },
            onDismiss: onDismiss
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
    let libraryViewModel: LibraryViewModel
    let readerSettingsStore: any ReaderSettingsStore

    // Audio / TTS
    let audioCoordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: TTSEngine
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController

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
    let chatPresenter: ChatPresenterImpl

    // Voice
    let voicePresenter: VoiceSessionPresenter

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
    let onboardingState: any OnboardingState
    let onboardingCoordinator: OnboardingCoordinator
    let readerDefaults: AppReaderDefaults
}

/// Tiny @MainActor-isolated reference box so LibraryViewModel's currentUserId
/// closure can be constructed before `self` is fully initialised. The closure
/// captures the box (a reference type), AppDependencies mutates `box.value`,
/// and LibraryViewModel reads the latest value on every `currentUserId()` call.
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
