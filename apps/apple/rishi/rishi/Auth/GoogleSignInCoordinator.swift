import Foundation
import GoogleSignIn

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
final class GoogleSignInCoordinator {

    enum ConfigurationError: LocalizedError, Equatable {
        case missingClientID(String)
        case presentationUnavailable
        case missingIDToken

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Google Sign-In is not configured. Set the iOS, server/web, and reversed iOS client IDs in the app configuration."
            case .presentationUnavailable:
                return "Google Sign-In could not find a window to present from."
            case .missingIDToken:
                return "Google did not return an ID token."
            }
        }

        var description: String {
            errorDescription ?? "Google Sign-In configuration failed."
        }
    }

    /// Starts the native Google flow and returns the Google ID token only.
    /// The token is exchanged for an app session by ``GoogleAuthEndpoint``.
    func signIn() async throws -> String {
        let configuration = try makeConfiguration()

        #if canImport(UIKit)
            guard let presentingViewController = presentingViewController() else {
                throw ConfigurationError.presentationUnavailable
            }

            GIDSignIn.sharedInstance.configuration = configuration
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presentingViewController
            )
            guard let token = result.user.idToken?.tokenString else {
                throw ConfigurationError.missingIDToken
            }
            return token
        #else
            throw ConfigurationError.presentationUnavailable
        #endif
    }

    static func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        // GIDSignInErrorCode.canceled is -5 in the official SDK. Keeping the
        // check at the NSError boundary avoids coupling the app to the SDK's
        // imported enum spelling across SDK releases.
        return (error as NSError).code == -5
    }

    private func makeConfiguration() throws -> GIDConfiguration {
        let info = Bundle.main.infoDictionary ?? [:]
        let clientID = try requiredConfigurationValue(
            info["GIDClientID"] as? String
        )
        let serverClientID = try requiredConfigurationValue(
            info["GIDServerClientID"] as? String
        )
        _ = try requiredConfigurationValue(
            info["GIDReversedClientID"] as? String
        )

        return GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )
    }

    private func requiredConfigurationValue(_ value: String?) throws -> String {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("$("),
              !value.hasPrefix("YOUR_") else {
            throw ConfigurationError.missingClientID("Google client ID")
        }
        return value
    }

    #if canImport(UIKit)
        private func presentingViewController() -> UIViewController? {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }

            var viewController = window?.rootViewController
            while let presented = viewController?.presentedViewController {
                viewController = presented
            }
            return viewController
        }
    #endif
}
