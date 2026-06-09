import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
import RishiCore

// MARK: - Scope mirror

/// Scope mirror so callers never have to import AuthenticationServices.
/// The production ``SystemSiwaPresenter`` translates these into
/// `[ASAuthorization.Scope]` at request time.
public enum SiwaScope: Hashable, Sendable {
    case fullName
    case email
}

// MARK: - Credential mirror

/// Sendable mirror of the fields ``SignInWithAppleCoordinator`` needs from
/// `ASAuthorizationAppleIDCredential`. `fullName` is reduced to a JSON-encoded
/// (display) string so we avoid the Sendable/PersonNameComponents friction in
/// Swift 6.
public struct SiwaCredential: Sendable, Equatable {
    public let identityToken: Data
    public let authorizationCode: Data
    /// Apple's stable `sub` (`user` field) — primary key for the worker.
    public let user: String
    /// Display-string projection of `PersonNameComponents`. Only present on the
    /// first authorization; `nil` on every subsequent sign-in per PITFALLS.md
    /// Pitfall 10.
    public let fullName: String?
    /// `nil` OR a `@privaterelay.appleid.com` address — both pass through
    /// unchanged to the worker.
    public let email: String?

    public init(
        identityToken: Data,
        authorizationCode: Data,
        user: String,
        fullName: String?,
        email: String?
    ) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.user = user
        self.fullName = fullName
        self.email = email
    }
}

// MARK: - Presenter seam

/// Seam between ``SignInWithAppleCoordinator`` and AuthenticationServices.
/// Tests inject a mock presenter that yields a canned credential or throws
/// cancellation; production uses ``SystemSiwaPresenter``.
public protocol SiwaPresenter: Sendable {
    func presentSignInRequest(scopes: Set<SiwaScope>) async throws -> SiwaCredential
}

#if canImport(AuthenticationServices) && canImport(UIKit)

/// Production presenter that drives `ASAuthorizationController` on the main
/// actor. The continuation lives on the delegate adapter; the `@MainActor`
/// isolation guarantees we obey UIKit threading rules. AuthenticationServices
/// import is gated behind `#if canImport(AuthenticationServices) &&
/// canImport(UIKit)` so the rest of the package (and `swift test` on a macOS
/// host) compiles cleanly.
@MainActor
public final class SystemSiwaPresenter: NSObject, SiwaPresenter,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<SiwaCredential, Error>?
    private weak var presentationAnchor: ASPresentationAnchor?

    public init(presentationAnchor: ASPresentationAnchor? = nil) {
        self.presentationAnchor = presentationAnchor
        super.init()
    }

    nonisolated public func presentSignInRequest(scopes: Set<SiwaScope>) async throws -> SiwaCredential {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SiwaCredential, Error>) in
            Task { @MainActor in
                self.continuation = cont
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                var asScopes: [ASAuthorization.Scope] = []
                if scopes.contains(.fullName) { asScopes.append(.fullName) }
                if scopes.contains(.email)    { asScopes.append(.email) }
                request.requestedScopes = asScopes
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let appleCred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = appleCred.identityToken,
              let authorizationCode = appleCred.authorizationCode else {
            self.continuation?.resume(throwing: RishiError.network(
                code: "siwa_missing_credential_fields",
                message: "ASAuthorizationAppleIDCredential missing identityToken or authorizationCode"
            ))
            self.continuation = nil
            return
        }
        var encodedFullName: String? = nil
        if let components = appleCred.fullName {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .long
            let s = formatter.string(from: components)
            encodedFullName = s.isEmpty ? nil : s
        }
        let credential = SiwaCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            user: appleCred.user,
            fullName: encodedFullName,
            email: appleCred.email
        )
        self.continuation?.resume(returning: credential)
        self.continuation = nil
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            self.continuation?.resume(throwing: RishiError.cancelled)
        } else {
            self.continuation?.resume(throwing: RishiError.network(
                code: "siwa_apple_sdk_error",
                message: "\(error)"
            ))
        }
        self.continuation = nil
    }

    // MARK: - Presentation anchor

    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let anchor = presentationAnchor { return anchor }
        // Fallback: use the first connected scene's key window.
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.keyWindow ?? windowScene.windows.first {
                return window
            }
        }
        // Last-resort empty window — should never happen at runtime.
        return UIWindow()
    }
}

#endif
