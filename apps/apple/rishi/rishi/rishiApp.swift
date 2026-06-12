//
//  rishiApp.swift
//  rishi
//
//  Created by Farid Matovu on 09/06/2026.
//

import SwiftUI
import RishiCore
import RishiAuth
import RishiBilling
import RishiLibrary
import RishiSync
#if canImport(UIKit)
import UIKit
#endif

@main
struct rishiApp: App {
    @State private var deps = AppDependencies()

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(RishiAppDelegate.self) private var appDelegate
    #endif

    init() {
        // Phase 7 (07-05): BGTaskScheduler.register MUST run before
        // applicationDidFinishLaunching returns. We're inside that window
        // here (rishiApp.init runs before the Scene body builds).
        deps.backgroundTaskCoordinator.register()
        deps.backgroundTaskCoordinator.scheduleAll()
        #if canImport(UIKit)
        // Hand the AppDelegate a back-reference so APNs + silent-push
        // callbacks can route into the sync engine.
        RishiAppDelegate.shared.dependencies = deps
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.rishiAuthService, deps.authServiceForEnvironment)
                .environment(deps.libraryViewModel)
                .environment(\.appDependencies, deps)
                .environment(\.macCommandRouter, deps.macCommandRouter)
                // Phase 13 / IAP-07 — make the StoreKit Manage
                // Subscriptions presenter visible to every SwiftUI view
                // (consumed by `ManageSubscriptionRow`).
                .environment(deps.manageSubscriptionPresenter)
        }
        // Phase 12 Plan 12-01 — Mac Catalyst menu-bar commands.
        // Universal (not Catalyst-gated) so iPad hardware-keyboard users
        // get the same ⌘ chords.
        .commands {
            RishiMenuCommands(router: deps.macCommandRouter)
        }
    }
}

#if canImport(UIKit)

/// UIKit delegate adapter for the SwiftUI `App`. Wires APNs registration
/// + silent-push reception into the Phase-7 sync engine.
///
/// Held alive by `@UIApplicationDelegateAdaptor`; `Self.shared` is set in
/// `application(_:didFinishLaunchingWithOptions:)` so `rishiApp.init` can
/// pump the back-reference to AppDependencies after both objects exist.
final class RishiAppDelegate: NSObject, UIApplicationDelegate {

    /// Latest delegate instance created by `@UIApplicationDelegateAdaptor`.
    /// Captured in `init()` so `rishiApp.init` can write the dependencies
    /// back-reference into the actual UIKit-owned delegate (rather than a
    /// stale singleton).
    nonisolated(unsafe) static var shared: RishiAppDelegate = RishiAppDelegate(boot: true)

    /// Pumped by `rishiApp.init` after `AppDependencies` is constructed.
    /// Weak so we don't keep the composition root alive past app teardown.
    weak var dependencies: AppDependencies?

    private nonisolated init(boot: Bool) {
        super.init()
    }

    override init() {
        super.init()
        Self.shared = self
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Request silent-push registration. Apple-recommended dispatch to
        // main avoids re-entering an in-flight launch sequence.
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard let deps = dependencies else { return }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        let platform = "ios"
        Task { [registrar = deps.apnsDeviceRegistrar] in
            do {
                try await registrar.register(
                    token: deviceToken,
                    platform: platform,
                    appVersion: version
                )
            } catch {
                // Silent — engine still works via BGTaskScheduler fallback.
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Silent — APNs registration is best-effort. BG fallback covers us.
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let deps = dependencies else {
            completionHandler(.noData)
            return
        }
        let sendableHandler = unsafeBitCast(
            completionHandler,
            to: (@Sendable (UIBackgroundFetchResult) -> Void).self
        )
        SilentPushHandler.handle(userInfo, engine: deps.syncEngine, completion: sendableHandler)
    }
}

#endif


