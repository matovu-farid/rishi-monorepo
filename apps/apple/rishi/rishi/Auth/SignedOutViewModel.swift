//
//  SignedOutViewModel.swift
//  rishi
//
//  Quick-SXI — view-model for SignedOutView.
//
//  Drives a simple state machine (.idle / .loading / .error) over the
//  injected AuthService. Owns NO AuthenticationServices/UIKit code — the
//  service (RishiAuthService) already encapsulates SIWA + Google flows
//  (Phase 3 plans 03-03 / 03-04 / 03-05).
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

    private let authService: (any AuthService)?

    init(authService: (any AuthService)?) {
        self.authService = authService
    }

    func signInWithApple() async {
        await runSignIn { service in
            _ = try await service.signInWithApple()
        }
    }

    func signInWithGoogle() async {
        await runSignIn { service in
            _ = try await service.signInWithGoogle()
        }
    }

    // MARK: - Helpers

    /// Drives the state machine: enter `.loading`, run the supplied
    /// service call, then transition to `.idle` on success or
    /// `.error(message)` on throw. Centralising the transition shape
    /// guarantees Apple and Google paths cannot drift.
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
