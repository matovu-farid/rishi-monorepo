import Foundation
import SwiftUI
import RishiCore
import RishiAPI
import RishiAuth
import RishiAudio
import RishiBilling
import RishiChat
import RishiDB
import RishiLibrary
import RishiOnboarding
import RishiReader
import RishiSettings
import RishiSync
import RishiVoice

/// Composition root for the rishi app. Constructed once by `rishiApp.init()`.
///
/// Holds references to every long-lived service the app needs. Actors do their
/// own isolation; this `@MainActor` class is just the holder that SwiftUI can
/// reach into synchronously to fetch them.
@MainActor
final class AppDependencies {

    // Auth + transport
    let keychain: KeychainSessionStore
    let tokenProvider: RishiAuthTokenProvider
    let workerClient: WorkerClient
    let siwaPresenter: SystemSiwaPresenter
    let googlePresenter: SystemGoogleWebAuthPresenter
    let siwaCoordinator: SignInWithAppleCoordinator
    let googleCoordinator: GoogleSignInCoordinator
    let authService: RishiAuthService

    // Persistence + library
    let dbQueue: DatabaseQueue
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let highlightStore: any HighlightStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let libraryViewModel: LibraryViewModel

    // Reader
    let readerSettingsStore: any ReaderSettingsStore

    // Audio / TTS (Phase 8 — composition root for the read-aloud stack)
    let audioCoordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: TTSEngine
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController

    // Sync (Phase 7 — composition root for the sync engine + background coord)
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

    // Chat (Phase 9 — composition root for the chat service + presenter seam)
    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let conversationLookup: ConversationLookup
    /// Phase 10 Plan 10-06: dual-conformer forwarder for BOTH `ChatDirtyHook`
    /// AND `VoiceTranscriptDirtyHook`. Replaces Phase 9's `AppChatDirtyHook`
    /// so the SyncEngine sees chat + voice transcript dirty marks through
    /// a single composition seam.
    let voiceDirtyAdapter: AppVoiceDirtyAdapter
    let chatService: RishiChatService
    /// Retained for the app lifetime. RootView observes
    /// `chatPresenter.pendingPresentation` to drive a `.sheet(item:)`
    /// presenting the chat panel for the active book.
    let chatPresenter: ChatPresenterImpl

    // Voice (Phase 10 — composition root for the realtime voice stack)
    /// Singleton presenter wiring the chat panel's voice button to the
    /// `RealtimeVoiceSession` lifecycle. `ChatPanelHost` binds
    /// `.fullScreenCover(isPresented:)` to `voicePresenter.isPresenting`.
    let voicePresenter: VoiceSessionPresenter

    // Billing (Phase 11 entitlement cache + Phase 13 StoreKit handoff)
    /// BILL-01: caches `EntitlementLevel` under "billing.entitlement.level"
    /// and refreshes from `/api/auth/get-session`. UI gates on
    /// `snapshot()` for synchronous reads.
    let entitlementService: EntitlementService
    /// IAP-07: drives the in-app "Manage Subscriptions" sheet via
    /// `AppStore.showManageSubscriptions(in:)` with an `itms-apps://`
    /// fallback. Installed into the SwiftUI environment by `RootView`
    /// so `ManageSubscriptionRow` can read it without prop-drilling.
    let manageSubscriptionPresenter: ManageSubscriptionPresenter

    // Phase 13 Wave-3 — full IAP object graph (plan 13-05).
    //
    /// IAP-02: actor wrapping `Product.products(for:)` + cached snapshot.
    let storeKitProductService: StoreKitProductService
    /// IAP-03: PurchaseService actor — enforces finish-after-verify and
    /// in-flight dedup. Tests inject via `PurchaseProtocol`.
    let purchaseService: PurchaseService
    /// IAP-04: long-lived `Transaction.updates` listener. Started at
    /// launch; survives the entire app lifetime.
    let transactionListener: TransactionListener
    /// IAP-05: shared reconciler. `EntitlementService` calls `setServer`;
    /// `PurchaseService` / `RestoreService` call `setOnDevice`.
    let entitlementReconciler: EntitlementReconciler
    /// IAP-05: live `@Observable` flag reading through the reconciler.
    /// Wave-3 UI (paywall, ManageSubscriptionRow, PremiumGateModifier)
    /// will switch to reading this directly via `@Environment` in a
    /// follow-up plan.
    let readerAppEntitlementFlag: ReaderAppEntitlementFlag
    /// IAP-06: user-initiated restore via `AppStore.sync()` +
    /// `Transaction.currentEntitlements` walk.
    let restoreService: RestoreService
    /// IAP-10: receipt verifier (existential). Normally
    /// `WorkerReceiptVerifier` (Release + DEBUG with the stub flag off).
    /// In DEBUG, when `UserDefaults RishiUseStubReceiptVerifier == YES`,
    /// `AppDependencies` swaps in `DebugStubReceiptVerifier` (Phase 14
    /// plan 14-07) so simulator builds can exercise the IAP flow without
    /// a live worker. The field name is retained for source-stability
    /// against existing tests; the runtime type may be either concrete
    /// verifier.
    let workerReceiptVerifier: any ReceiptVerifier

    // Settings (Phase 11 — telemetry opt-in)
    /// SET-02: backs the Privacy section toggle. Sink forwards to
    /// `RishiLogging.setSentryEnabled(_:)` so opting out mutes uploads.
    let telemetryStore: any TelemetryStore

    // Onboarding (Phase 11 — first-run flow)
    /// ONB-01 / ONB-02: persisted onboarding flags + the @Observable
    /// coordinator driving the welcome → first-reader-hint sequence.
    let onboardingState: any OnboardingState
    let onboardingCoordinator: OnboardingCoordinator

    /// SET-01 Reader Defaults section bindings — app-wide theme + font
    /// applied when a book has no per-book override.
    let readerDefaults: AppReaderDefaults

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

    init() {
        // Worker base URL (override via env for staging tests).
        let baseURLString = ProcessInfo.processInfo.environment["RISHI_API_URL"]
            ?? "https://api.fidexa.org"
        let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.fidexa.org")!

        // 1. Keychain — single instance backing the token provider AND the auth service.
        let keychain = KeychainSessionStore()
        self.keychain = keychain

        // 2. Token provider reads from the same keychain.
        let tokenProvider = RishiAuthTokenProvider(keychain: keychain)
        self.tokenProvider = tokenProvider

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
        self.workerClient = workerClient

        // 4. Presenters (must be constructed on main actor — we ARE the main actor here).
        let siwaPresenter = SystemSiwaPresenter()
        let googlePresenter = SystemGoogleWebAuthPresenter()
        self.siwaPresenter = siwaPresenter
        self.googlePresenter = googlePresenter

        // 5. Coordinators wrap the presenters + worker client.
        let siwaCoordinator = SignInWithAppleCoordinator(
            workerClient: workerClient,
            presenter: siwaPresenter
        )
        let googleCoordinator = GoogleSignInCoordinator(
            workerClient: workerClient,
            presenter: googlePresenter,
            baseURL: baseURL,
            callbackScheme: "rishi"
        )
        self.siwaCoordinator = siwaCoordinator
        self.googleCoordinator = googleCoordinator

        // 6. Auth service aggregates everything.
        let authService = RishiAuthService(
            workerClient: workerClient,
            siwaCoordinator: siwaCoordinator,
            googleCoordinator: googleCoordinator,
            keychain: keychain
        )
        self.authService = authService

        // 7. Persistence layer (GRDB queue under Documents).
        let documentsURL = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first!
        let dbURL = documentsURL.appendingPathComponent("rishi.sqlite")
        let dbQueue: DatabaseQueue
        do {
            dbQueue = try RishiDB.makeDatabaseQueue(at: dbURL)
        } catch {
            fatalError("Failed to open rishi.sqlite at \(dbURL): \(error)")
        }
        self.dbQueue = dbQueue

        // 8. Stores.
        let bookStore = GRDBBookStore(dbQueue: dbQueue)
        let positionStore = GRDBPositionStore(dbQueue: dbQueue)
        let highlightStore = GRDBHighlightStore(dbQueue: dbQueue)
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore

        // 8b. Reader settings (per-book theme persistence via UserDefaults).
        self.readerSettingsStore = UserDefaultsReaderSettingsStore()

        // 9. Library file storage (cover extractors for the two v1 formats).
        let bookFileStorage = BookFileStorage(
            rootURL: documentsURL,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(),
                "epub": EpubCoverExtractor(),
            ]
        )
        self.bookFileStorage = bookFileStorage

        // 9b. Sync — composition root for the engine + background coordinator.
        //
        // Built BEFORE the ImportCoordinator so the coordinator's onBookImported
        // callback can route into `syncEngine.markBookDirty(_:)` for SYNC-01.
        let syncMetadataStore = GRDBSyncMetadataStore(dbQueue: dbQueue)
        self.syncMetadataStore = syncMetadataStore

        let syncQueue = SyncQueue(metadataStore: syncMetadataStore)
        self.syncQueue = syncQueue

        let syncStatus = SyncStatus()
        self.syncStatus = syncStatus

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
        self.bookUploader = bookUploader
        self.positionUploader = positionUploader
        self.highlightUploader = highlightUploader
        self.remoteChangeFetcher = remoteChangeFetcher
        self.changeApplier = changeApplier

        let syncEngine = SyncEngine(
            config: .init(),
            queue: syncQueue,
            metadataStore: syncMetadataStore,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            fetcher: remoteChangeFetcher,
            applier: changeApplier
        )
        self.syncEngine = syncEngine

        self.backgroundTaskCoordinator = BackgroundTaskCoordinator(engine: syncEngine)
        self.apnsDeviceRegistrar = APNsDeviceRegistrar(workerClient: workerClient)

        // 10. Import coordinator pulls the current user id from the auth service
        // at import time (handles sign-out / sign-in transitions correctly).
        // SYNC-01: every successful import fans into the sync engine so the
        // book uploads on the next wave.
        self.importCoordinator = ImportCoordinator(
            storage: bookFileStorage,
            currentUserId: {
                await authService.currentUser?.id
            },
            onBookImported: { [syncEngine] bookId in
                await syncEngine.markBookDirty(bookId)
            }
        )

        // 11. Sample-book installers (first-run alice.epub + sample.pdf).
        self.sampleBookInstaller = SampleBookInstaller(storage: bookFileStorage)
        self.sampleReaderInstaller = SampleReaderInstaller(storage: bookFileStorage)

        // 12. Library view model. `currentUserId` reads from a heap-allocated
        // box that RootView pumps via `cachedUserId`. We can't capture `self`
        // here (it's still mid-init), so we route through a tiny box and keep
        // a reference for AppDependencies's setter to update.
        let userIdBox = UserIdBox()
        self.userIdBox = userIdBox
        self.libraryViewModel = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: bookFileStorage,
            currentUserId: { userIdBox.value }
        )

        // 13. Bind the @Observable SyncStatus to the engine actor. Fire-and-forget
        //     Task because init can't await; the actor handles the hop.
        Task { [syncEngine, syncStatus] in
            await syncEngine.bind(status: syncStatus)
        }

        // 14. Audio / TTS stack (Phase 8). Real AVAudioEngine + MediaPlayer
        //     adapters on iOS / Catalyst; Fake adapters everywhere else so
        //     dev-host swift build still resolves.
        let audioStack = Self.makeAudioStack(workerClient: workerClient)
        self.audioCoordinator = audioStack.coordinator
        self.ttsState = audioStack.state
        self.ttsEngine = audioStack.engine
        self.ttsSettingsStore = audioStack.settingsStore
        self.nowPlayingController = audioStack.nowPlaying

        // 15. Chat stack (Phase 9). GRDB stores for conversations + messages,
        //     ConversationLookup actor over the conversation store, the
        //     RishiChatService actor wired with AppVoiceDirtyAdapter
        //     (forwards to SyncEngine for BOTH chat + voice transcript dirty
        //     marks — Plan 10-06), and the @Observable ChatPresenterImpl
        //     that RootView binds a sheet to.
        let conversationStore = GRDBConversationStore(dbQueue: dbQueue)
        let messageStore = GRDBMessageStore(dbQueue: dbQueue)
        let conversationLookup = ConversationLookup(store: conversationStore)
        let voiceDirtyAdapter = AppVoiceDirtyAdapter(syncEngine: syncEngine)
        // `userIdProvider` reads from the same userIdBox the LibraryViewModel
        // uses — RootView pumps it after auth resolves. Chat turns will fail
        // with `RishiError.unauthenticated` until then (intentional).
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
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.conversationLookup = conversationLookup
        self.voiceDirtyAdapter = voiceDirtyAdapter
        self.chatService = chatService
        self.chatPresenter = ChatPresenterImpl()

        // 16. Voice stack (Phase 10 Plan 10-06). Single `VoiceSessionPresenter`
        //     wiring the chat-panel voice button to a `RealtimeVoiceSession`.
        //     Reuses the SAME `audioCoordinator` from the Phase-8 TTS stack so
        //     `.voice` mode acquisition pre-empts active TTS playback per
        //     VOICE-04. The dirty-hook is the same dual-conformer adapter
        //     wired into ChatService above.
        self.voicePresenter = VoiceSessionPresenter(
            coordinator: audioStack.coordinator,
            workerClient: workerClient,
            messageStore: messageStore,
            conversationLookup: conversationLookup,
            userIdProvider: { [userIdBox] in userIdBox.value },
            dirtyHook: voiceDirtyAdapter
        )

        // 17. Billing stack. Phase 11 entitlement cache + Phase 13
        //     full native StoreKit IAP graph (plan 13-05 Wave-3 wiring).
        //     The Stripe portal handoff is removed — anti-steering 3.1.1
        //     incompatibility (see 13-07-PLAN.md).
        self.entitlementService = EntitlementService(workerClient: workerClient)
        self.manageSubscriptionPresenter = ManageSubscriptionPresenter()

        // Phase 13 plan 13-05 — full IAP object graph.
        //
        // Wiring order matches RESEARCH §3:
        //   Wave 1: products → verifier → purchase service → listener
        //           → reconciler (+ flag)
        //   Wave 2: restore + manage
        //   Launch hooks: replayUnfinished() then listener.start()
        //   Optional: pre-warm products when StoreKitIAPFlag is ON
        let productService = StoreKitProductService()
        // Phase 14 plan 14-07 — DEBUG stub swap.
        // In DEBUG, when `defaults write org.fidexa.rishi RishiUseStubReceiptVerifier -bool YES`
        // is set, route receipt verification through the in-process
        // `DebugStubReceiptVerifier` (always-verified, 30-day premium) so
        // the simulator IAP flow can be exercised offline. Release builds
        // skip the entire branch (stub type is `#if DEBUG`-stripped).
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
        let reconciler = EntitlementReconciler()
        let entitlementFlag = ReaderAppEntitlementFlag(reconciler: reconciler)
        let restoreService = RestoreService(reconciler: reconciler)

        self.storeKitProductService = productService
        self.workerReceiptVerifier = receiptVerifier
        self.purchaseService = purchaseService
        self.transactionListener = listener
        self.entitlementReconciler = reconciler
        self.readerAppEntitlementFlag = entitlementFlag
        self.restoreService = restoreService

        // Launch hooks: replay any unfinished transactions FIRST (so the
        // listener doesn't double-handle them), then install the
        // long-lived `Transaction.updates` listener. RESEARCH §2.3, §2.4.
        Task.detached(priority: .background) { [purchaseService, listener] in
            await purchaseService.replayUnfinished()
            await listener.start()
        }

        // Pre-warm the product catalog when the StoreKit IAP flag is ON
        // (saves a paywall-render-time round-trip). When OFF (release
        // default until ASC product setup completes), skip — avoids an
        // unnecessary network call.
        if StoreKitIAPFlag.isEnabled {
            Task.detached(priority: .background) { [productService] in
                _ = try? await productService.load()
            }
        }

        // 18. Settings stack — telemetry sink forwards to RishiLogging which
        //     drops Sentry uploads on opt-out (SET-02).
        self.telemetryStore = UserDefaultsTelemetryStore(sink: AppTelemetrySink())

        // 19. Onboarding stack — UserDefaults-backed flags + the @Observable
        //     coordinator driving the first-run flow (ONB-01 / ONB-02).
        let onboardingState = UserDefaultsOnboardingState()
        self.onboardingState = onboardingState
        self.onboardingCoordinator = OnboardingCoordinator(state: onboardingState)

        // 20. Reader defaults (app-wide). Per-book overrides still come from
        //     `readerSettingsStore`; these defaults drive the Settings
        //     Reader section pickers.
        self.readerDefaults = AppReaderDefaults()
    }

    // MARK: - Paywall factory (Phase 13 plan 13-05)

    /// Build a fresh `PaywallViewModel` wired to the full IAP graph.
    ///
    /// RootView (or a future Wave-3 paywall host) calls this when
    /// presenting the live paywall sheet. The VM is freshly constructed
    /// per presentation so its `loadState` / `purchaseState` start clean
    /// — long-lived services (product cache, listener) stay shared.
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
    ///
    /// Called by RootView when the user taps the chat button in the reader
    /// toolbar or "Ask about this" in a selection menu. Returns `nil` only
    /// when the lookup throws — a non-recoverable storage failure that we
    /// surface to the UI by skipping the sheet.
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
    /// Conversations tab — bypasses the lookup since the conversation is
    /// already in hand.
    func makeChatPanelViewModel(conversation: Conversation) -> ChatPanelViewModel {
        ChatPanelViewModel(
            conversation: conversation,
            bookId: conversation.bookId,
            chatService: chatService,
            messageStore: messageStore
        )
    }

    /// Builds a fresh ``ConversationsListViewModel`` for the Conversations
    /// tab. The VM hydrates itself in its `.task` modifier from
    /// `conversationStore` + `messageStore`.
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
    private struct AudioStack {
        let coordinator: AudioSessionCoordinator
        let state: TTSPlaybackState
        let engine: TTSEngine
        let settingsStore: any TTSSettingsStore
        let nowPlaying: NowPlayingController
    }

    @MainActor
    private static func makeAudioStack(workerClient: WorkerClient) -> AudioStack {
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

    /// Construct a fresh `ReaderTTSBridge` for one reader sheet. Each
    /// bridge owns its own `TTSPassageTracker` so multiple readers can run
    /// independent passage streams; the engine + state + settings store
    /// are shared (single audio session).
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
    /// wiring every dependency through. `SettingsSheet` (the rishi-app
    /// wrapper) calls this from its `body`.
    ///
    /// `onSignedOut` and `onAccountDeleted` are both invoked AFTER the sheet
    /// dismisses — RootView clears `currentUser` in response so the
    /// signed-out path takes over.
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
                // Phase 13 — Manage Subscription is now driven directly by
                // `ManageSubscriptionRow` reading the
                // `ManageSubscriptionPresenter` from the SwiftUI
                // environment (installed by `RootView`). This closure is
                // a redundant safety path for `SettingsScreen` source
                // compat until plan 13-05 / 13-06 cleans up the call
                // chain.
                Task { @MainActor in
                    await presenter.present()
                }
            },
            onDismiss: onDismiss
        )
    }

    private let userIdBox: UserIdBox

    var authServiceForEnvironment: any AuthService { authService }
}

/// Tiny @MainActor-isolated reference box so LibraryViewModel's currentUserId
/// closure can be constructed before `self` is fully initialised. The closure
/// captures the box (a reference type), AppDependencies mutates `box.value`,
/// and LibraryViewModel reads the latest value on every `currentUserId()` call.
@MainActor
private final class UserIdBox {
    var value: UserID? = nil
}

// MARK: - StoreKit product-fetching conformance (Phase 13)
//
// `PurchaseService` depends on a `ProductFetching` protocol (declared in
// RishiBilling alongside `ReceiptVerifier`) so its unit tests can inject
// a single-product fetcher without an SKTestSession daemon. The
// production `StoreKitProductService` actor already exposes a matching
// `rawProduct(for:)` accessor; this one-line extension adopts the
// protocol so AppDependencies can pass the service directly without an
// intermediate adapter.
extension StoreKitProductService: ProductFetching {}

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
