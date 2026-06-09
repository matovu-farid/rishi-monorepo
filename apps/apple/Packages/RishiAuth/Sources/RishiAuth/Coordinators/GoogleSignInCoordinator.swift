import Foundation
import RishiCore
import RishiLogging
import RishiAPI

/// Drives the Google OAuth flow:
///   1. Build `<baseURL>/desktop/start?provider=google&device=ios`
///   2. Open it in ``GoogleWebAuthPresenter`` and await the rishi:// callback
///   3. Extract the `token` query parameter from the callback
///   4. POST it to `/api/auth/google` via ``WorkerClient`` to mint a ``Session``
///
/// Note: this file deliberately does NOT import AuthenticationServices — that
/// dependency is fenced inside ``SystemGoogleWebAuthPresenter``. Keeping the
/// coordinator SDK-free lets the dev-host `swift test` run the live flow
/// against a mock presenter without dragging UIKit in.
public actor GoogleSignInCoordinator {

    private let workerClient: WorkerClient
    private let presenter: any GoogleWebAuthPresenter
    private let baseURL: URL
    private let callbackScheme: String

    public init(
        workerClient: WorkerClient,
        presenter: any GoogleWebAuthPresenter,
        baseURL: URL = URL(string: "https://api.fidexa.org")!,
        callbackScheme: String = "rishi"
    ) {
        self.workerClient = workerClient
        self.presenter = presenter
        self.baseURL = baseURL
        self.callbackScheme = callbackScheme
    }

    public func signIn() async throws -> Session {
        Log.event("auth.google.started", level: .info)

        let startURL = Self.buildStartURL(base: baseURL)
        let callbackURL: URL
        do {
            callbackURL = try await presenter.presentWebAuth(
                url: startURL,
                callbackScheme: callbackScheme
            )
        } catch let error as RishiError {
            if case .cancelled = error {
                Log.event("auth.google.cancelled", level: .info)
            }
            throw error
        }

        guard let token = Self.parseCallbackToken(callbackURL) else {
            throw RishiError.network(
                code: "google_oauth_missing_token",
                message: "Callback URL missing ?token= parameter: \(callbackURL)"
            )
        }

        let response = try await workerClient.send(
            GoogleSignInEndpoint(body: .init(idToken: token))
        )

        let session = Session(
            token: response.sessionToken,
            userId: UUID(uuidString: response.userId) ?? UUID(),
            email: response.email,
            provider: .google,
            issuedAt: Date(),
            expiresAt: nil
        )
        Log.event("auth.google.completed", level: .info)
        return session
    }

    // MARK: - Pure helpers (nonisolated for testability)

    /// Build `<base>/desktop/start?provider=google&device=ios`, tolerating a
    /// trailing slash on `base`. `URL.appendingPathComponent` collapses any
    /// duplicate separator before URLComponents re-emits the query items.
    nonisolated static func buildStartURL(base: URL) -> URL {
        let withPath = base.appendingPathComponent("desktop/start")
        var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "device",   value: "ios"),
        ]
        return components.url!
    }

    /// Extract the `token` query parameter from the rishi:// callback URL.
    /// Returns nil if the URL has no query items or no `token` key.
    /// An empty-string value (e.g. `?token=`) is intentionally returned as
    /// `""` — the worker is the source of truth for "is this token valid".
    nonisolated static func parseCallbackToken(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "token" })?.value
    }
}
