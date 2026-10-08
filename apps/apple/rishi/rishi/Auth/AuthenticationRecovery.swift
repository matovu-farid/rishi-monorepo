import Foundation

/// User-facing recovery never carries a bearer, refresh token or server body.
struct AuthenticationRecovery: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case temporarilyUnavailable
        case credentialUnavailable
        case signInRequired
        case cleanupIncomplete
    }

    let kind: Kind

    var message: String {
        switch kind {
        case .temporarilyUnavailable:
            "Your sign-in could not be checked right now. Try again."
        case .credentialUnavailable:
            "Your saved sign-in could not be accessed. Try again."
        case .signInRequired:
            "Sign in again to continue."
        case .cleanupIncomplete:
            "Sign-out could not finish. Retry before changing accounts."
        }
    }

    static func forError(_ error: Error) -> Self? {
        if let failure = error as? CredentialAuthenticationFailure {
            switch failure {
            case .accountChanged: return nil
            case .signedOut: return nil
            case .unavailable(.retirementIncomplete): return .init(kind: .cleanupIncomplete)
            case .unavailable: return .init(kind: .credentialUnavailable)
            case .reauthenticationRequired, .definitiveRejection: return .init(kind: .signInRequired)
            }
        }
        return .init(kind: .temporarilyUnavailable)
    }
}
