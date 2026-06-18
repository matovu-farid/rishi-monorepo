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
/// in ``BackgroundSyncLifecycle/registerSynchronously()`` — that helper runs
/// at the very top of the AppDelegate's `didFinishLaunching`, BEFORE
/// bootstrap. The handlers capture the lifecycle weakly and short-circuit to
/// `task.setTaskCompleted(success: false)` when ``services`` is still nil
/// (i.e. the OS fires a BG task before bootstrap has completed). Plan 34-14
/// SRP split — the BGTask + Auto-Sync gate policy lives in
/// ``BackgroundSyncLifecycle``, reachable via ``backgroundSyncLifecycle``.
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

    // MARK: - Sync lifecycle (BGTask + Auto-Sync gate)

    /// Owns the BGTask register/drive + silent-push + the Auto-Sync gate
    /// policy (plan 34-14 SRP split). Lazily constructed on first access so
    /// the `nonisolated init()` stays trivial; the AppDelegate reaches it via
    /// ``backgroundSyncLifecycle`` to register BGTasks and route push.
    @ObservationIgnored
    private lazy var _backgroundSyncLifecycle = BackgroundSyncLifecycle(dependencies: self)

    /// The sync-lifecycle policy object. The AppDelegate forwards BGTask
    /// registration, APNs token, and silent-push callbacks here.
    var backgroundSyncLifecycle: BackgroundSyncLifecycle { _backgroundSyncLifecycle }

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
            await ServiceGraphFactory.build(userIdBox: userIdBox)
        }.value
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
/// them inside ``ServiceGraphFactory/build(userIdBox:)`` and they stay
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

private struct ServicesKey: EnvironmentKey {
    @MainActor static let defaultValue: BootstrappedServices? = nil
}

extension EnvironmentValues {
    var services: BootstrappedServices? {
        get { self[ServicesKey.self] }
        set { self[ServicesKey.self] = newValue }
    }
}

private struct CurrentUserKey: EnvironmentKey {
    @MainActor static let defaultValue: User? = nil
}

extension EnvironmentValues {
    var currentUser: User? {
        get { self[CurrentUserKey.self] }
        set { self[CurrentUserKey.self] = newValue }
    }
}
