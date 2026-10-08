




import SwiftUI
import TipKit
import SwiftData
import StoreKit

#if DEBUG
enum RishiE2EConfiguration {
    static var isRealAuth: Bool {
        ProcessInfo.processInfo.arguments.contains("--rishi-e2e-real-auth")
            || ProcessInfo.processInfo.environment["RISHI_E2E_REAL_AUTH"] == "1"
    }

    static var isReset: Bool {
        ProcessInfo.processInfo.arguments.contains("--rishi-e2e-reset")
    }

    static var fixtureURL: URL? {
        let prefix = "--rishi-e2e-fixture="
        guard let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: String(value), isDirectory: false)
    }

    static var manifestURL: URL? {
        let prefix = "--rishi-e2e-manifest="
        guard let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: String(value), isDirectory: false)
    }

    static func clearAccountScopedPreferences(for userID: UUID) {
        // This is the only account-keyed preference currently used by the
        // library UI. Keep the reset narrow so a DEBUG/E2E run does not erase
        // unrelated preferences belonging to other local accounts.
        UserDefaults.standard.removeObject(
            forKey: "rishi.library.firstBookPrompt.seen.\(userID.uuidString)"
        )
    }

    /// Staged final reset path. The caller captures admission before async
    /// launch/reset work; cleanup is owned by the actual app transaction.
    @MainActor
    static func beginCanonicalReset(dependencies: AppDependencies, authority: SessionCredentialAuthority,
                                    expectedTicket: CredentialAttemptTicket,
                                    clearPreferences: (UUID) -> Void) throws -> Task<Void, Never> {
        guard dependencies.usesCredentialAuthority(authority), authority.attemptTicket() == expectedTicket else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        let transaction = try dependencies.beginAccountChange(expectedCredentialTicket: expectedTicket)
        guard let transition = transaction.credentialTransition else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        if case .loaded(let outgoing) = transition.outgoing {
            guard authority.performIfCurrent(transition, mutation: {
                clearPreferences(DerivedUserID.from(outgoing.lease.rawUserID))
            }) else { throw CredentialAuthenticationFailure.accountChanged }
        }
        guard let retirement = dependencies.retireCredentialAccount(transaction) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        return retirement
    }
}
#endif

#if canImport(UIKit)
    import UIKit
    import UserNotifications
#endif
#if os(iOS) && canImport(CarPlay)
    import CarPlay
#endif

@main
struct rishiApp: App {
    @State private var deps: AppDependencies
    @State private var router: AppRouter
    @State private var trialPresentationCoordinator = TrialIntroPresentationCoordinator()
    #if targetEnvironment(macCatalyst)
        @State private var readerWindows = ReaderWindowCoordinator()
    #endif

    @Environment(\.scenePhase) private var scenePhase

    var currentUserBox = CurrentUserBox()

    #if canImport(UIKit)
        @UIApplicationDelegateAdaptor(RishiAppDelegate.self) private
            var appDelegate
    #endif

    init() {
        let dependencies = AppDependencies.shared
        _deps = State(initialValue: dependencies)
        _router = State(initialValue: AppRouter(sharedReaderAccountIDProvider: { dependencies.cachedUserId }))
        SentryLaunchConfiguration.start()
        #if DEBUG
        if let sink = SimulatorDumpSink.make() {
            Log.installSink(sink)
            Log.event("diagnostics.sink.installed", data: ["path": sink.directory.path])
        } else {
            Log.error("diagnostics.sink.install_failed")
        }
        #endif
    
    }

    private func makeRootWorkflow(adapter: CredentialAuthenticationAdapter) throws -> RootWorkflowOwner {
        guard let services = deps.services else { throw CredentialAuthenticationFailure.accountChanged }
        let bookService = services.library.sessionBookService
        let resources = RootWorkflowOwner.Resources(
            packages: services.library.sharePackageService,
            prepareBook: { book, ownerID in try await bookService.prepare(book: book, ownerId: ownerID) },
            api: services.sharedReadingAPIFactory, registry: services.sharedReadingSessionRegistry,
            pendingInvites: .anonymous, makeTransport: { SharedReadingSignalingClient() })
        #if targetEnvironment(macCatalyst)
        let host = RootWorkflowOwner.Host(router: router, readerWindows: readerWindows)
        #else
        let host = RootWorkflowOwner.Host(router: router)
        #endif
        return try RootWorkflowOwner(dependencies: deps, authentication: adapter, currentUser: currentUserBox,
                                     resources: resources, host: host)
    }

    var body: some Scene {
        WindowGroup {

        
            Group {
                if let adapter = deps.credentialAuthenticationAdapter {
                    switch Result(catching: { try makeRootWorkflow(adapter: adapter) }) {
                    case .success(let workflow):
                        RootView(credentialAdapter: adapter, workflow: workflow)
                            .environment(deps.services!.billing.store)
                            .environment(deps.services!.billing.customerEntitlements)
                    case .failure:
                        ContentUnavailableView("Rishi could not open this session", systemImage: "exclamationmark.triangle")
                    }
                } else if deps.bootstrapFailure != nil {
                    ContentUnavailableView {
                        Label("Rishi could not start", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Retry") { Task { await deps.bootstrap() } }
                    }
                } else { ProgressView().accessibilityLabel("Loading Rishi") }
            }
                .onOpenURL { url in
                    // Google Sign-In can deliver OAuth callbacks through the
                    // SwiftUI scene rather than UIApplicationDelegate. Keep
                    // the delegate bridge below as a compatibility fallback;
                    // URL events continue to propagate to existing deep-link
                    // handlers.
                    _ = GoogleSignInCoordinator.handle(url)
                    if !AppRouter.enqueueShareOrSessionToken(from: url) {
                        router.handle(url: url, bookStore: nil, conversationStore: nil)
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    guard let url = userActivity.webpageURL else { return }
                    if !AppRouter.enqueueShareOrSessionToken(from: url) {
                        router.handle(url: url, bookStore: nil, conversationStore: nil)
                    }
                }
                .environment(currentUserBox)
                .environment(\.appDependencies, deps)
                .environment(deps)
                .environment(\.macCommandRouter, deps.macCommandRouter)
                .environment(router)
                .environment(trialPresentationCoordinator)
                #if targetEnvironment(macCatalyst)
                    .environment(readerWindows)
                    .modifier(ReaderWindowCoordinatorConfiguration(coordinator: readerWindows))
                #endif
         

                .task {
                    #if canImport(UIKit)
                        // `deps` is a State-backed reference and is not
                        // installed until the app view exists. Wiring the
                        // delegate here avoids constructing a second
                        // AppDependencies instance during App.init.
                        appDelegate.dependencies = deps
                    #endif

                    #if DEBUG
                    if RishiE2EConfiguration.isReset {
                        do {
                            let retirement = try RishiE2EConfiguration.beginCanonicalReset(
                                dependencies: deps, authority: deps.credentialAuthority,
                                expectedTicket: deps.credentialAuthority.attemptTicket(),
                                clearPreferences: RishiE2EConfiguration.clearAccountScopedPreferences)
                            // This DEBUG launch task owns reset, not an initiating auth request.
                            await retirement.value
                            if case .success? = deps.credentialRetirementResult {
                                currentUserBox.signedOutAfterCredentialClear()
                            }
                        } catch { Log.error("debug.account-reset.failed", error: error) }
                    }
                    #endif
                    await deps.bootstrap()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1",
                       !RishiE2EConfiguration.isRealAuth,
                       let adapter = deps.credentialAuthenticationAdapter {
                        let rawID = "7F7B3D2A-8B8D-4D2E-9D1D-9B4C8F7E6A10"
                        let user = User(id: DerivedUserID.from(rawID), email: "ui-test@rishi.invalid", name: "Rishi UI Test")
                        do {
                            try await adapter.completeSignIn(session: Session(token: "ui-test", userId: rawID, email: user.email),
                                refreshToken: nil, user: user, attempt: adapter.beginAttempt(), debugOnboarding: true) {
                                    currentUserBox.signIn(user: user)
                                }
                        } catch { Log.error("debug.ui-test-signin.failed", error: error) }
                    }
                    #endif
                    #if os(iOS) && canImport(WatchConnectivity)
                    if let owner = deps.services?.audio.playbackOwner {
                        appDelegate.attachWatchServices(
                            owner,
                            accountGeneration: deps.accountGeneration,
                            hasAccount: deps.cachedUserId != nil
                        )
                    }
                    #endif
                    await refreshEntitlementSnapshot(reason: .launch)
                }
                .task {
                    // Configure and load your tips at app launch.
                    do {
                        #if DEBUG
                        try Tips.resetDatastore()
                        try Tips.configure([
                            .displayFrequency(.immediate)
                        ])
                        if ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1" {
                            Tips.hideAllTipsForTesting()
                        }
                        #else
                        try Tips.configure()
                        #endif
                    }
                    catch {
                        // Handle TipKit errors
                        print("Error initializing TipKit \(error.localizedDescription)")
                    }
                }
                
        }
#if targetEnvironment(macCatalyst)
        .defaultSize(width: 1400, height: 1000)
#endif
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                Task { @MainActor in
                    await deps.services?.voice.presenter.requestEnd()
                }
                #if DEBUG
                Task.detached {
                    await Log.flushSharedReadingDiagnostics(timeout: 1)
                }
                #endif
            case .active:
                Task { @MainActor in
                    #if os(iOS) && canImport(WatchConnectivity)
                    appDelegate.refreshWatchAccountState(
                        generation: deps.accountGeneration,
                        hasAccount: deps.cachedUserId != nil
                    )
                    #endif
                    await deps.services?.systemIntegration.spotlight.requestReindex()
                    await refreshEntitlementSnapshot(reason: .foreground)
                }
            default:
                break
            }
        }
        .commands {
            RishiMenuCommands(
                router: deps.macCommandRouter,
                account: deps.macAccountMenu
            )
        }

        #if targetEnvironment(macCatalyst)
            WindowGroup(id: "reader", for: ReaderWindowInput.self) { input in
                if let input = input.wrappedValue {
                    CatalystReaderWindow(input: input)
                        .environment(currentUserBox)
                        .environment(\.appDependencies, deps)
                        .environment(deps)
                        .environment(\.macCommandRouter, deps.macCommandRouter)
                        .environment(router)
                        .environment(readerWindows)
                } else {
                    ProgressView()
                }
            }
            // Apple Books-like document window proportions. This is only the
            // initial scene size; user resizing is never overridden after
            // the reader opens.
            .defaultSize(width: 1400, height: 1000)
            .commands {
                ReaderWindowMenuCommands(
                    dependencies: deps,
                    readerWindows: readerWindows
                )
            }
        #endif
    }

    /// Launch/foreground entitlement-snapshot refresh, per both specs'
    /// "The client performs entitlement sync at launch, foreground...".
    /// Guards on a stored session so a genuinely signed-out fresh install
    /// does not fire one guaranteed-401, log-spamming `/api/billing/me`
    /// call before the user has ever signed in — the same
    /// `Keychain.load(.userId)` check `RootView.realBodyContent`'s own
    /// bootstrap `.task` already uses.
    ///
    /// Also calls `RestoreService.refreshOnDeviceEntitlementAtLaunch()` so
    /// StoreKit on-device reconcile + entitlement-sync fire from this same
    /// hook (storekit-four-products plan deferred the scenePhase observer
    /// here to avoid a second lifecycle observer).
    private func refreshEntitlementSnapshot(
        reason: EntitlementRefreshCoordinator.RefreshReason
    ) async {
        guard deps.services != nil else { return }
        if case .launch = reason {
            await deps.refreshEntitlementsAtLaunch()
            return
        }
        guard let snapshot = try? deps.credentialAuthority.snapshot() else { return }
        _ = await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(reason: reason,
            credentialContext: .normal(snapshot.lease))
    }
}

#if canImport(UIKit)

    final class RishiAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

        nonisolated(unsafe) static var shared: RishiAppDelegate =
            RishiAppDelegate(boot: true)

        private var backgroundSyncRegistered = false

        weak var dependencies: AppDependencies? {
            didSet {
                registerBackgroundSyncIfNeeded()
                #if os(iOS) && canImport(WatchConnectivity)
                dependencies?.installSynchronousAccountTransitionFence { [weak self] in
                    self?.watchPlaybackBridge?.invalidateForAccountChange()
                    self?.watchConnectivityCoordinator?.clearPublishedSnapshot()
                }
                #endif
            }
        }

        #if os(iOS) && canImport(WatchConnectivity)
        private var watchConnectivityCoordinator: WatchConnectivityCoordinator?
        private var watchConnectivityAdapter: WatchConnectivityDelegateAdapter?
        private var watchPlaybackBridge: WatchPlaybackBridge?
        private var watchAccountChangeObserver: NSObjectProtocol?
        private var watchAccountTransitionObserver: NSObjectProtocol?
        #endif

        private func registerBackgroundSyncIfNeeded() {
            guard !backgroundSyncRegistered, let dependencies else { return }
            dependencies.backgroundSyncLifecycle.registerSynchronously()
            backgroundSyncRegistered = true
        }

        private nonisolated init(boot: Bool) {
            super.init()
        }

        override init() {
            super.init()
            Self.shared = self
        }

        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication
                .LaunchOptionsKey: Any]? = nil
        ) -> Bool {

            #if os(iOS) && canImport(WatchConnectivity)
            let coordinator = WatchConnectivityCoordinator()
            watchConnectivityCoordinator = coordinator
            watchConnectivityAdapter = WatchConnectivityDelegateAdapter(coordinator: coordinator)
            watchAccountChangeObserver = NotificationCenter.default.addObserver(
                forName: .rishiAccountDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let generation = (notification.userInfo?["generation"] as? NSNumber)?.uint64Value ?? 0
                let hasAccount = (notification.userInfo?["hasAccount"] as? NSNumber)?.boolValue ?? false
                Task { @MainActor [weak self] in
                    self?.refreshWatchAccountState(generation: generation, hasAccount: hasAccount)
                }
            }
            watchAccountTransitionObserver = NotificationCenter.default.addObserver(
                forName: .rishiAccountTransitionStarted,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let bridge = self.watchPlaybackBridge else { return }
                    if let snapshot = bridge.redactedSnapshotForCurrentClient() {
                        self.watchConnectivityCoordinator?.publish(snapshot: snapshot)
                    } else {
                        self.watchConnectivityCoordinator?.clearPublishedSnapshot()
                    }
                }
            }
            #endif

            registerBackgroundSyncIfNeeded()

            UNUserNotificationCenter.current().delegate = self
            DispatchQueue.main.async {
                // Registering for a device token does not show the permission
                // prompt. The alert permission is requested in context by the
                // library's notification primer.
                application.registerForRemoteNotifications()
            }
            return true
        }

        #if os(iOS) && canImport(WatchConnectivity)
        @MainActor
        func attachWatchServices(
            _ owner: ReadAloudPlaybackOwner,
            accountGeneration: UInt64,
            hasAccount: Bool
        ) {
            guard let watchConnectivityCoordinator else { return }
            let bridge = WatchPlaybackBridge(owner: owner)
            do {
                if hasAccount {
                    try bridge.installVerifiedMarker(minimumAccountGeneration: accountGeneration)
                } else {
                    bridge.invalidateForAccountChange()
                }
                watchPlaybackBridge = bridge
                watchConnectivityCoordinator.attach(handler: bridge)
            } catch {
                // Fail closed but keep the bridge attached. A later account
                // event or foreground bootstrap can retry marker installation.
                bridge.invalidateForAccountChange()
                watchPlaybackBridge = bridge
                watchConnectivityCoordinator.attach(handler: bridge)
            }
        }

        @MainActor
        func refreshWatchAccountState(generation: UInt64, hasAccount: Bool) {
            guard let bridge = watchPlaybackBridge else { return }
            guard hasAccount else {
                bridge.invalidateForAccountChange()
                if let snapshot = bridge.redactedSnapshotForCurrentClient() {
                    watchConnectivityCoordinator?.publish(snapshot: snapshot)
                } else {
                    watchConnectivityCoordinator?.clearPublishedSnapshot()
                }
                return
            }
            do {
                try bridge.installVerifiedMarker(minimumAccountGeneration: generation)
                if let snapshot = bridge.redactedSnapshotForCurrentClient() {
                    watchConnectivityCoordinator?.publish(snapshot: snapshot)
                } else {
                    watchConnectivityCoordinator?.clearPublishedSnapshot()
                }
            } catch {
                bridge.invalidateForAccountChange()
                if let snapshot = bridge.redactedSnapshotForCurrentClient() {
                    watchConnectivityCoordinator?.publish(snapshot: snapshot)
                } else {
                    watchConnectivityCoordinator?.clearPublishedSnapshot()
                }
            }
        }
        #endif

        #if os(iOS) && canImport(CarPlay)
        func application(
            _ application: UIApplication,
            configurationForConnecting connectingSceneSession: UISceneSession,
            options: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            if connectingSceneSession.role == .carTemplateApplication {
                let configuration = UISceneConfiguration(
                    name: "CarPlaySceneConfiguration",
                    sessionRole: connectingSceneSession.role
                )
                configuration.sceneClass = CPTemplateApplicationScene.self
                configuration.delegateClass = CarPlaySceneDelegate.self
                return configuration
            }
            return UISceneConfiguration(
                name: "Default Configuration",
                sessionRole: connectingSceneSession.role
            )
        }
        #endif

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler:
                @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound, .badge])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        func application(
            _ app: UIApplication,
            open url: URL,
            options: [UIApplication.OpenURLOptionsKey: Any] = [:]
        ) -> Bool {
            if AppRouter.enqueueShareToken(from: url) {
                return true
            }
            return GoogleSignInCoordinator.handle(url)
        }

        func application(
            _ application: UIApplication,
            continue userActivity: NSUserActivity,
            restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
        ) -> Bool {
            guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
                  let url = userActivity.webpageURL
            else { return false }
            // Only claim the activity when it is a share URL. Returning true
            // for every web link would swallow ordinary book/conversation
            // Universal Links before SwiftUI's router can handle them.
            return AppRouter.enqueueShareToken(from: url)
        }

        func application(
            _ application: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            guard let deps = dependencies else { return }
            let version =
                (Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                    as? String) ?? "1.0.0"
            #if targetEnvironment(macCatalyst)
                let platform = "macos-catalyst"
            #else
                let platform = "ios"
            #endif

            Task { @MainActor in
                await deps.backgroundSyncLifecycle.registerDeviceToken(
                    deviceToken,
                    platform: platform,
                    appVersion: version
                )
            }
        }

        func application(
            _ application: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Error
        ) {

        }

        func applicationWillTerminate(_ application: UIApplication) {
            Task { @MainActor in
                await dependencies?.services?.voice.presenter.requestEnd()
            }
        }

        func application(
            _ application: UIApplication,
            didReceiveRemoteNotification userInfo: [AnyHashable: Any],
            fetchCompletionHandler completionHandler:
                @escaping (UIBackgroundFetchResult) -> Void
        ) {
            guard let deps = dependencies else {
                completionHandler(.noData)
                return
            }
            let sendableHandler = unsafeBitCast(
                completionHandler,
                to: (@Sendable (UIBackgroundFetchResult) -> Void).self
            )
       

            Task { @MainActor in
                await deps.backgroundSyncLifecycle.handleSilentPush(
                    userInfo,
                    completion: sendableHandler
                )
             
           
                
            }
        }
    }

#endif
