import Foundation
import SwiftUI
import RishiCore
import RishiAPI
import RishiAuth
import RishiAudio
import RishiChat
import RishiDB
import RishiLibrary
import RishiReader
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
