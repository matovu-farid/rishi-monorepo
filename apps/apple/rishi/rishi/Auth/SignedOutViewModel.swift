import Foundation
import Observation
import RishiCore

@MainActor
@Observable
final class SignedOutViewModel {

    enum State: Equatable {
        case idle
        case loading
        case error(String)

        case signedIn
    }

    private(set) var state: State = .idle

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var isSignInButtonDisabled: Bool {
        switch state {
        case .loading, .signedIn: return true
        case .idle, .error: return false
        }
    }

    var errorMessage: String? {
        if case .error(let m) = state { return m }
        return nil
    }

    private(set) var authService: (any AuthService)?

    var onSignedIn: ((User) -> Void)?

    init(authService: (any AuthService)?) {
        self.authService = authService
    }

    func setAuthService(_ service: (any AuthService)?) {
        self.authService = service
    }

    func signInWithApple() async {

        switch state {
        case .loading, .signedIn:
            return
        case .idle, .error:
            break
        }
        await runSignIn { service in
            try await service.signInWithApple()
        }
    }

    private func runSignIn(
        _ call: (any AuthService) async throws -> User
    ) async {
        guard let authService else {
            state = .error("Authentication is not available.")
            return
        }
        state = .loading
        do {
            let user = try await call(authService)
            state = .signedIn
            if let onSignedIn {
                self.onSignedIn = nil
                onSignedIn(user)
            }
        } catch {
            state = .error(Self.humanReadable(error))
        }
    }

    private static func humanReadable(_ error: any Error) -> String {
        let raw = String(describing: error)
        return raw.isEmpty ? "Sign-in failed." : raw
    }
}
