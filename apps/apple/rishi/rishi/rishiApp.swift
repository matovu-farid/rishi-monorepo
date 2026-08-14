




import SwiftUI
import TipKit
import SwiftData
import StoreKit

#if canImport(UIKit)
    import UIKit
    import UserNotifications
#endif
#if os(iOS) && canImport(CarPlay)
    import CarPlay
#endif

@main
struct rishiApp: App {
    @State private var deps = AppDependencies.shared
    @State private var router = AppRouter()
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
        SentryLaunchConfiguration.start()
    
    }

    var body: some Scene {
        WindowGroup {

        
            RootView()
                .onOpenURL { url in
                    // Google Sign-In can deliver OAuth callbacks through the
                    // SwiftUI scene rather than UIApplicationDelegate. Keep
                    // the delegate bridge below as a compatibility fallback;
                    // URL events continue to propagate to existing deep-link
                    // handlers.
                    _ = GoogleSignInCoordinator.handle(url)
                    if !AppRouter.enqueueShareToken(from: url) {
                        router.handle(url: url, bookStore: nil, conversationStore: nil)
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    guard let url = userActivity.webpageURL else { return }
                    if !AppRouter.enqueueShareToken(from: url) {
                        router.handle(url: url, bookStore: nil, conversationStore: nil)
                    }
                }
                .environment(currentUserBox)
                .environment(\.appDependencies, deps)
                .environment(deps)
                .environment(\.macCommandRouter, deps.macCommandRouter)
                .environment(SubscriptionService.shared)
                .environment(router)
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
                    await deps.bootstrap()
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
            case .active:
                Task { await refreshEntitlementSnapshot(reason: .foreground) }
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
        await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(reason: reason)
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
            }
        }

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
