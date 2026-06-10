import Foundation
import RishiAPI
import RishiLogging

#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
import UIKit
#endif

/// Presenter seam — the unit tests inject a stub; the app injects
/// `SystemBillingPortalPresenter` (defined inside the UIKit fence below).
///
/// Mirrors the Phase-3 `SystemSiwaPresenter` pattern: a protocol-typed
/// presenter keeps `swift test` runnable on the dev host without UIKit,
/// while the production app gets a real `ASWebAuthenticationSession`.
public protocol BillingPortalPresenter: Sendable {
    /// Open `url` in a system browser session and return when the user
    /// closes or the URL flow completes. The Stripe portal flow never
    /// redirects back to a custom scheme — the user just closes the sheet,
    /// so this returns `Void` on success.
    func present(url: URL) async throws
}

/// Errors raised by ``BillingPortalService/openPortal()``.
public enum BillingPortalError: Error, Equatable, Sendable {
    /// Worker returned a string that isn't a parseable `http(s)` URL.
    case invalidURL(String)
    /// `WorkerClient` failed to reach the worker or decode the response.
    case network(String)
    /// User dismissed the system browser sheet without completing.
    case userCancelled
}

/// Opens the Stripe customer portal in `ASWebAuthenticationSession`.
///
/// BILL-02: "Manage Subscription" opens `/api/billing/portal` URL via
/// `ASWebAuthenticationSession` (NOT Safari) per `READER-APP-ENTITLEMENT.md`
/// + `STACK.md` "Subscriptions / Billing".
///
/// Reader-App entitlement gates the visibility of the CALLER (the
/// `ManageSubscriptionRow` in 11-03). This service itself is entitlement-
/// agnostic — if the row is hidden, `openPortal()` is never invoked.
public actor BillingPortalService {

    private let workerClient: WorkerClient
    private let presenter: any BillingPortalPresenter

    public init(workerClient: WorkerClient, presenter: any BillingPortalPresenter) {
        self.workerClient = workerClient
        self.presenter = presenter
    }

    /// Request a one-time portal URL from the worker and forward it to the
    /// injected presenter. Errors bubble up as ``BillingPortalError`` so the
    /// caller never sees a raw transport error.
    public func openPortal() async throws {
        let response: BillingPortalEndpoint.PortalResponse
        do {
            response = try await workerClient.send(BillingPortalEndpoint())
        } catch {
            Log.event("billing.portal.network_failed", level: .error,
                      data: ["error": String(describing: error)])
            throw BillingPortalError.network(String(describing: error))
        }

        guard let url = URL(string: response.url),
              url.scheme?.hasPrefix("http") == true else {
            Log.event("billing.portal.invalid_url", level: .error,
                      data: ["url": response.url])
            throw BillingPortalError.invalidURL(response.url)
        }

        Log.event("billing.portal.opening", level: .info,
                  data: ["host": url.host ?? ""])
        try await presenter.present(url: url)
    }
}

// MARK: - System presenter (iOS / Catalyst only)

#if canImport(AuthenticationServices) && canImport(UIKit)

/// Production presenter — `ASWebAuthenticationSession` with
/// `prefersEphemeralWebBrowserSession = true` so the portal flow does not
/// share Safari cookies (same rationale as the Phase-3 Google OAuth
/// presenter — see PITFALLS.md Pitfall 9).
///
/// `callbackURLScheme: nil` — the Stripe portal does NOT redirect back to
/// a custom scheme. The user closes the sheet manually when they're done;
/// the session completes with a `canceledLogin` error which we map to a
/// silent successful return.
@MainActor
public final class SystemBillingPortalPresenter: NSObject, BillingPortalPresenter, ASWebAuthenticationPresentationContextProviding {

    public override init() { super.init() }

    public func present(url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
                if let nsErr = error as NSError?,
                   nsErr.domain == ASWebAuthenticationSessionError.errorDomain,
                   nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    cont.resume(returning: ())
                    return
                }
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: ())
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
    }
}

#endif
