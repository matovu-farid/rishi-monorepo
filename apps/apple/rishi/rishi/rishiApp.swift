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
    @State private var router = AppRouter()

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(RishiAppDelegate.self) private var appDelegate
    #endif

    init() {
        // Phase 19 plan 19-01 — BGTaskScheduler.register MUST run before
        // application(_:didFinishLaunchingWithOptions:) returns per Apple's
        // contract. The AppDelegate is the canonical home for that hook;
        // it calls `deps.backgroundSyncLifecycle.registerSynchronously()`
        // from inside `didFinishLaunchingWithOptions`. We forward the
        // back-reference here so the delegate can find the live
        // AppDependencies instance.
        #if canImport(UIKit)
        RishiAppDelegate.shared.dependencies = deps
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.rishiAuthService, deps.services?.authService)
                .environment(\.appDependencies, deps)
                .environment(\.macCommandRouter, deps.macCommandRouter)
                .environment(router)
                // Phase 19 plan 19-01 — drive the off-main bootstrap from
                // the WindowGroup root. `.task` runs once when the root
                // first appears; RootView's outer `if deps.services !=
                // nil` guard renders a ProgressView until this completes.
                .task {
                    await deps.bootstrap()
                }
        }
        // Phase 12 Plan 12-01 — Mac Catalyst menu-bar commands.
        // Universal (not Catalyst-gated) so iPad hardware-keyboard users
        // get the same ⌘ chords.
        .commands {
            RishiMenuCommands(router: deps.macCommandRouter, account: deps.macAccountMenu)
        }
    }
}

#if canImport(UIKit)

/// UIKit delegate adapter for the SwiftUI `App`. Wires APNs registration
/// + silent-push reception into the Phase-7 sync engine.
///
/// Phase 19 plan 19-01 — also owns the BGTaskScheduler registration call
/// (was previously in `rishiApp.init`). Apple's contract requires
/// registration before `application(_:didFinishLaunchingWithOptions:)`
/// returns; that call site is the canonical home.
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
        // Phase 19 plan 19-01 — BGTaskScheduler.register MUST run before
        // this method returns per Apple's contract. Plan 34-14 SRP split —
        // the registration + Auto-Sync gate now live in
        // BackgroundSyncLifecycle; the delegate just forwards to it. The
        // handlers await bootstrap before driving syncEngine.runOnce().
        if let deps = dependencies {
            deps.backgroundSyncLifecycle.registerSynchronously()
        }

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
        // Phase 19 plan 19-01 / plan 34-14 — services may still be nil if
        // APNs registration races against bootstrap. BackgroundSyncLifecycle
        // owns the bootstrap-await buffering before reaching apnsDeviceRegistrar.
        // KEEP: explicit @MainActor required to touch `deps` (the @MainActor
        // composition root); registrar is itself an actor so the worker
        // call hops off main internally — body is fire-and-forget.
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
        // Phase 19 plan 19-01 / plan 34-14 — silent push may arrive before
        // bootstrap completes (push wakes the app from a cold-launch
        // background window). BackgroundSyncLifecycle owns the bootstrap-await
        // buffering AND the Phase-33 Auto-Sync gate (§G2 site 2) in one place;
        // the delegate just forwards. Manual Sync Now is never gated.
        // KEEP: explicit @MainActor to touch `deps`; the lifecycle hops into
        // the syncEngine actor on its own — body is short.
        Task { @MainActor in
            await deps.backgroundSyncLifecycle.handleSilentPush(
                userInfo,
                completion: sendableHandler
            )
        }
    }
}

#endif

