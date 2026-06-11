//
//  SignedOutViewModel.swift
//  rishi
//
//  Quick-SXI — view-model for SignedOutView.
//
//  Drives a simple state machine (.idle / .loading / .error) over the
//  injected AuthService. Owns NO AuthenticationServices/UIKit code — the
//  service (RishiAuthService) already encapsulates the SIWA flow
//  (Phase 3 plan 03-03). Phase 15 plan 15-03: Google Sign-In removed.
//

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
    }

    private(set) var state: State = .idle

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let m) = state { return m }
        return nil
    }

    private(set) var authService: (any AuthService)?

    init(authService: (any AuthService)?) {
        self.authService = authService
    }

    /// Late-injects the auth service after construction. Used by
    /// `SignedOutView` to thread the `@Environment(\.rishiAuthService)`
    /// value into a view-model that was eagerly constructed (non-Optional
    /// `@State`) so the Observation runtime tracks property changes
    /// without going through an `Optional<@Observable>` indirection.
    /// Idempotent: passing nil after a non-nil value clears the service.
    func setAuthService(_ service: (any AuthService)?) {
        self.authService = service
    }

    func signInWithApple() async {
        await runSignIn { service in
            _ = try await service.signInWithApple()
        }
    }

    // MARK: - Helpers

    /// Drives the state machine: enter `.loading`, run the supplied
    /// service call, then transition to `.idle` on success or
    /// `.error(message)` on throw. Centralising the transition shape
    /// keeps every sign-in path on a single state-machine implementation.
    private func runSignIn(
        _ call: (any AuthService) async throws -> Void
    ) async {
        guard let authService else {
            state = .error("Authentication is not available.")
            return
        }
        state = .loading
        do {
            try await call(authService)
            state = .idle
        } catch {
            state = .error(Self.humanReadable(error))
        }
    }

    /// Surface a non-empty error string for the UI. v1 maps any error to
    /// `String(describing:)` — Phase 11/12 follow-up will localise these
    /// against `RishiCore.RishiError` cases when the worker error model
    /// stabilises.
    private static func humanReadable(_ error: any Error) -> String {
        let raw = String(describing: error)
        return raw.isEmpty ? "Sign-in failed." : raw
    }
}
