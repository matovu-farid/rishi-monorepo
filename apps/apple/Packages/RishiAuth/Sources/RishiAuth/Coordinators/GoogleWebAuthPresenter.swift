import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
import RishiCore

/// Seam between ``GoogleSignInCoordinator`` and AuthenticationServices'
/// ``ASWebAuthenticationSession``. Tests inject a mock that yields a canned
/// callback URL or throws cancellation; production uses
/// ``SystemGoogleWebAuthPresenter``.
public protocol GoogleWebAuthPresenter: Sendable {

    /// Open `url` in a system web auth session whose callback scheme is
    /// `callbackScheme` (e.g. `"rishi"`), then return the final callback URL the
    /// session reported when the browser redirected to the registered scheme.
    func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL
}

#if canImport(AuthenticationServices) && canImport(UIKit)

/// Production presenter that drives ASWebAuthenticationSession on the main actor.
///
/// PITFALLS.md Pitfall 9: pins `prefersEphemeralWebBrowserSession = true` so
/// Safari cookies aren't shared (no "Allow this app to sign you in" prompt and
/// no embedded-useragent rejection from Google).
@MainActor
public final class SystemGoogleWebAuthPresenter: NSObject, GoogleWebAuthPresenter,
    ASWebAuthenticationPresentationContextProviding {

    private weak var presentationAnchor: ASPresentationAnchor?

    public init(presentationAnchor: ASPresentationAnchor? = nil) {
        self.presentationAnchor = presentationAnchor
        super.init()
    }

    nonisolated public func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    if let error {
                        if let asError = error as? ASWebAuthenticationSessionError,
                           asError.code == .canceledLogin {
                            cont.resume(throwing: RishiError.cancelled)
                        } else {
                            cont.resume(throwing: RishiError.network(
                                code: "google_oauth_sdk_error",
                                message: "\(error)"
                            ))
                        }
                        return
                    }
                    guard let callbackURL else {
                        cont.resume(throwing: RishiError.network(
                            code: "google_oauth_empty_callback",
                            message: "ASWebAuthenticationSession completed with no URL and no error"
                        ))
                        return
                    }
                    cont.resume(returning: callbackURL)
                }
                session.presentationContextProvider = self
                // PITFALLS.md Pitfall 9: avoid cookie-sharing prompt + Safari
                // session leakage that Apple flags at review.
                session.prefersEphemeralWebBrowserSession = true
                _ = session.start()
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor = presentationAnchor { return anchor }
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.keyWindow ?? windowScene.windows.first {
                return window
            }
        }
        return UIWindow()
    }
}

#endif
