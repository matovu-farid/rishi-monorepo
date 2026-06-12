//
//  SignedOutViewModel.swift
//  rishi
//
//  Quick-SXI — view-model for SignedOutView.
//
//  Drives a state machine (.idle / .loading / .error / .signedIn) over
//  the injected AuthService. Owns NO AuthenticationServices/UIKit code —
//  the service (RishiAuthService) already encapsulates the SIWA flow
//  (Phase 3 plan 03-03). Phase 15 plan 15-03: Google Sign-In removed.
//
//  Hotfix `siwa-double-fire-403`: success terminates in `.signedIn`
//  (NOT `.idle`) and fires `onSignedIn` exactly once so RootView can
//  swap to the signed-in tree. The `.signedIn` terminal state guards
//  the re-tap window between VM completion and view tear-down.
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
        /// Terminal state entered after a successful sign-in. The view
        /// stays mounted briefly while RootView swaps to the signed-in
        /// tree on its next render; during that window the button MUST
        /// remain disabled so a stray re-tap (or trampoline tap on the
        /// still-active button area before the view tears down) does not
        /// re-fire `signInWithApple()`.
        ///
        /// See `.planning/debug/resolved/siwa-double-fire-403.md` —
        /// without this terminal state the VM transitioned back to
        /// `.idle`, the button re-enabled, and a second
        /// `auth.siwa.started` fired during the RootView transition
        /// window, producing a 403 from Better Auth's
        /// `/api/auth/sign-in/social` (replay/session-attached rejection
        /// on the second POST).
        case signedIn
    }

    private(set) var state: State = .idle

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// True while the VM is mid-sign-in OR after a successful sign-in.
    /// Both states must disable the Apple button: `.loading` for the
    /// obvious in-flight reason, `.signedIn` to prevent a re-fire during
    /// the RootView render window between the success callback firing
    /// and the signed-in tree mounting.
    var isSignInButtonDisabled: Bool {
        switch state {
        case .loading, .signedIn: return true
        case .idle, .error:       return false
        }
    }

    var errorMessage: String? {
        if case .error(let m) = state { return m }
        return nil
    }

    private(set) var authService: (any AuthService)?

    /// Side-effect closure fired exactly once after the first successful
    /// `signInWithApple()` call. Used by `SignedOutView` to notify
    /// `RootView` that it should re-read `auth.currentUser` and mount the
    /// signed-in tree. `RishiAuthService` does NOT publish an observable
    /// `currentUser` stream, so this callback is the wire that closes the
    /// "VM completed sign-in -> RootView swaps the view" loop. Cleared
    /// after firing so it cannot trigger a duplicate transition.
    var onSignedIn: ((User) -> Void)?

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
        // Re-entrancy guard: once we are mid-flight OR have already
        // succeeded, drop subsequent calls on the floor. This is the
        // FALSIFIABLE root-cause guard for `siwa-double-fire-403` — a
        // second tap (or a synthesised tap during the RootView swap)
        // must NOT enter `runSignIn` again.
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

    // MARK: - Helpers

    /// Drives the state machine: enter `.loading`, run the supplied
    /// service call, then transition to `.signedIn` on success or
    /// `.error(message)` on throw. Centralising the transition shape
    /// keeps every sign-in path on a single state-machine implementation.
    ///
    /// On success we fire `onSignedIn` exactly once with the User
    /// returned by the service and clear the closure — RootView
    /// consumes the User to flip its `currentUser` state, which
    /// unmounts SignedOutView on the next render. The terminal
    /// `.signedIn` state keeps the button disabled during that window
    /// so no second invocation can race the render swap.
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

    /// Surface a non-empty error string for the UI. v1 maps any error to
    /// `String(describing:)` — Phase 11/12 follow-up will localise these
    /// against `RishiCore.RishiError` cases when the worker error model
    /// stabilises.
    private static func humanReadable(_ error: any Error) -> String {
        let raw = String(describing: error)
        return raw.isEmpty ? "Sign-in failed." : raw
    }
}
