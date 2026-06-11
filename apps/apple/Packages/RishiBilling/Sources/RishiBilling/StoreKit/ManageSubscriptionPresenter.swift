#if canImport(UIKit)
import UIKit
#endif
import Foundation
import Observation
import StoreKit
import RishiLogging

/// Outcome of a single ``ManageSubscriptionInvoker/present()`` call.
///
/// - `presentedInAppSheet`: the system in-app sheet was successfully
///   presented via `AppStore.showManageSubscriptions(in:)` (preferred —
///   keeps the user inside the app per anti-steering / 13-RESEARCH §13 Q1).
/// - `openedFallbackURL`: the in-app sheet was unavailable on this runtime
///   (no foreground scene, or the StoreKit API threw) and we routed to
///   the allow-listed `itms-apps://apps.apple.com/account/subscriptions`
///   URL instead.
public enum ManageSubscriptionOutcome: Sendable, Equatable {
    case presentedInAppSheet
    case openedFallbackURL
}

/// Errors surfaced by ``DefaultManageSubscriptionInvoker``.
public enum ManageSubscriptionError: Error, Sendable, Equatable {
    /// Built without UIKit (pure macOS / non-Catalyst). There is no
    /// in-app sheet API on that runtime; caller decides whether to fall
    /// back to a help link, a different settings deep link, or a no-op.
    case noPlatformSupport
}

/// Protocol seam so tests can inject a stub that records calls instead of
/// driving the real StoreKit sheet.
///
/// Production wires ``DefaultManageSubscriptionInvoker``; tests inject a
/// recording stub (see `ManageSubscriptionPresenterTests.StubInvoker`).
public protocol ManageSubscriptionInvoker: Sendable {
    /// Invokes the in-app Manage Subscriptions sheet (or fallback URL).
    ///
    /// - Returns: ``ManageSubscriptionOutcome/presentedInAppSheet`` if the
    ///   in-app sheet rendered, ``ManageSubscriptionOutcome/openedFallbackURL``
    ///   if the implementation routed to `itms-apps://`.
    /// - Throws: ``ManageSubscriptionError/noPlatformSupport`` (or other
    ///   implementation-defined errors) only when neither path worked.
    @MainActor
    func present() async throws -> ManageSubscriptionOutcome
}

/// Production invoker — drives `AppStore.showManageSubscriptions(in:)`
/// and falls back to `itms-apps://apps.apple.com/account/subscriptions`
/// when the in-app sheet is unavailable (no foreground scene, or the
/// StoreKit API throws — Catalyst is uneven, per 13-RESEARCH §13 Q1).
///
/// The fallback URL is allow-listed in
/// `apps/apple/scripts/check-anti-steering.sh` and is the Apple-blessed
/// deep link for Manage Subscriptions (`itms-apps://` scheme).
@MainActor
public final class DefaultManageSubscriptionInvoker: ManageSubscriptionInvoker {

    public init() {}

    public func present() async throws -> ManageSubscriptionOutcome {
        #if canImport(UIKit)
        // Find the foreground active window scene. On Mac Catalyst the
        // foreground scene may be `.foregroundInactive` in some configs;
        // we accept the first `.foregroundActive` and otherwise fall
        // through to the URL fallback (don't block the user behind a
        // scene lookup edge case).
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        if let scene {
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                Log.event("iap.manage.in_app_sheet_presented", level: .info)
                return .presentedInAppSheet
            } catch {
                Log.event(
                    "iap.manage.in_app_sheet_failed_fallback",
                    level: .warning,
                    data: ["error": String(describing: error)]
                )
                // Fall through to URL fallback.
            }
        } else {
            Log.event("iap.manage.no_active_scene_fallback", level: .warning)
        }
        // Fallback: itms-apps URL. Allow-listed in anti-steering script.
        let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions")!
        await UIApplication.shared.open(url)
        return .openedFallbackURL
        #else
        // Pure macOS / non-Catalyst — no UIKit; throw so the caller can
        // route to a help link or a different flow.
        throw ManageSubscriptionError.noPlatformSupport
        #endif
    }
}

/// MainActor presenter bound to the SwiftUI UI. Wraps the invoker so
/// views can fire a synchronous tap (`Task { await presenter.present() }`)
/// and read back ``lastOutcome`` / ``lastError`` for badge / toast UI.
///
/// Wave-3 paywall (plan 13-05) shares this same presenter for its
/// in-paywall Manage link.
///
/// `@Observable` so SwiftUI views consuming the presenter through
/// `@Environment(ManageSubscriptionPresenter.self)` re-evaluate when
/// ``lastOutcome`` / ``lastError`` change (e.g. a future "manage failed
/// — try again" toast).
@MainActor
@Observable
public final class ManageSubscriptionPresenter {

    private let invoker: any ManageSubscriptionInvoker

    /// The outcome of the most recent ``present()`` call. `nil` if no
    /// call has run yet OR the most recent call threw (see ``lastError``).
    public private(set) var lastOutcome: ManageSubscriptionOutcome?

    /// The error from the most recent ``present()`` call, if any. Cleared
    /// on the next successful call.
    public private(set) var lastError: Error?

    public init(invoker: any ManageSubscriptionInvoker = DefaultManageSubscriptionInvoker()) {
        self.invoker = invoker
    }

    /// Drive the underlying invoker. Errors are caught and surfaced via
    /// ``lastError`` rather than thrown — SwiftUI tap handlers don't
    /// have a clean place to handle a throwing async call inline.
    public func present() async {
        do {
            let outcome = try await invoker.present()
            self.lastOutcome = outcome
            self.lastError = nil
        } catch {
            self.lastError = error
            self.lastOutcome = nil
            Log.event(
                "iap.manage.present_threw",
                level: .error,
                data: ["error": String(describing: error)]
            )
        }
    }
}
