import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
import RishiCore

#if canImport(AuthenticationServices) && canImport(UIKit)

/// Production presenter that drives `ASAuthorizationController` on the main
/// actor. The continuation lives on the delegate adapter; the `@MainActor`
/// isolation guarantees we obey UIKit threading rules. AuthenticationServices
/// import is gated behind `#if canImport(AuthenticationServices) &&
/// canImport(UIKit)` so the rest of the package (and `swift test` on a macOS
/// host) compiles cleanly.
///
/// Plan 15-06: generates a per-request nonce via ``Nonce/generate()`` and
/// binds the SHA-256 hex digest into `ASAuthorizationAppleIDRequest.nonce`
/// BEFORE calling `performRequests()`. The same hex is forwarded back to the
/// coordinator on the `SiwaCredential.nonceHex` field so it can post the
/// matching value to Better Auth.
@MainActor
public final class SystemSiwaPresenter: NSObject, SiwaPresenter,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<SiwaCredential, Error>?
    private weak var presentationAnchor: ASPresentationAnchor?
    /// Hex digest of the in-flight nonce. Set immediately before
    /// `performRequests()`; cleared on terminal callback. Needed because the
    /// SiwaCredential we build in
    /// `authorizationController(_:didCompleteWithAuthorization:)` must carry
    /// the SAME hex we bound to the request — Apple does not echo the nonce
    /// out on the credential side.
    private var pendingNonceHex: String?

    public init(presentationAnchor: ASPresentationAnchor? = nil) {
        self.presentationAnchor = presentationAnchor
        super.init()
    }

    nonisolated public func presentSignInRequest(scopes: Set<SiwaScope>) async throws -> SiwaCredential {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SiwaCredential, Error>) in
            // KEEP: ASAuthorizationController requires MainActor presentation;
            // explicit @MainActor hop to set up the credential request and
            // assign the continuation on the MainActor-isolated presenter.
            Task { @MainActor in
                self.continuation = cont
                let (_, nonceHex) = Nonce.generate()
                self.pendingNonceHex = nonceHex
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                var asScopes: [ASAuthorization.Scope] = []
                if scopes.contains(.fullName) { asScopes.append(.fullName) }
                if scopes.contains(.email)    { asScopes.append(.email) }
                request.requestedScopes = asScopes
                // PITFALLS Pitfall 1: bind the SHA-256 hex digest to the
                // Apple request. Apple stores this string verbatim in the
                // JWT `nonce` claim — Better Auth's check is string-equality
                // (apple.mjs:58), so the SAME hex goes on the wire to
                // Better Auth as `idToken.nonce`.
                request.nonce = nonceHex
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
              let authorizationCode = appleCred.authorizationCode,
              let nonceHex = self.pendingNonceHex else {
            self.continuation?.resume(throwing: RishiError.network(
                code: "siwa_missing_credential_fields",
                message: "ASAuthorizationAppleIDCredential missing identityToken, authorizationCode, or in-flight nonce"
            ))
            self.continuation = nil
            self.pendingNonceHex = nil
            return
        }
        // PITFALLS Pitfall 8: capture .givenName / .familyName as discrete
        // fields. Better Auth concatenates them with a space at
        // apple.mjs:77, so passing structured components round-trips losslessly.
        let name: SiwaName? = appleCred.fullName.map {
            SiwaName(firstName: $0.givenName, lastName: $0.familyName)
        }
        // PITFALLS Pitfall 8: on second sign-in Apple returns
        // PersonNameComponents with both fields nil — collapse to nil so the
        // coordinator can omit `idToken.user` entirely (sending empty strings
        // would clobber the user row Better Auth already has).
        let projectedName: SiwaName? = {
            guard let name = name,
                  (name.firstName != nil && !(name.firstName?.isEmpty ?? true))
                  || (name.lastName != nil && !(name.lastName?.isEmpty ?? true))
            else { return nil }
            return name
        }()
        let credential = SiwaCredential(
            identityTokenData: identityToken,
            authorizationCode: authorizationCode,
            user: appleCred.user,
            fullName: projectedName,
            email: appleCred.email,
            nonceHex: nonceHex
        )
        self.continuation?.resume(returning: credential)
        self.continuation = nil
        self.pendingNonceHex = nil
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
        self.pendingNonceHex = nil
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
