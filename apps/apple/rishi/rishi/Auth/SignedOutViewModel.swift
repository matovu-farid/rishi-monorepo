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

    // RED-step stubs: deliberately do not mutate `state` so the
    // SignedOutViewModelTests suite fails before the GREEN commit.
    func signInWithApple() async {
        // intentionally empty — implemented in the GREEN commit
    }

    func signInWithGoogle() async {
        // intentionally empty — implemented in the GREEN commit
    }
}
