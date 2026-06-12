//
//  SignedOutViewModelTests.swift
//  rishiTests
//
//  Quick-SXI — Swift Testing suite proving the SignedOutViewModel state
//  machine. Stub AuthService records call counts and can be configured
//  to throw or to block on a CheckedContinuation so the test can observe
//  the in-flight loading state.
//
//  Phase 15 plan 15-03: legacy social-provider call-count + failure-path
//  tests were deleted along with the second sign-in method on
//  `AuthService`. The late-injection regression test was reframed around
//  the Apple path so the signed-out-button-noop guard still ships.
//

import Foundation
import Testing
import os
import RishiCore
@testable import rishi

// MARK: - StubAuthService

/// `@unchecked Sendable` mirrors the Phase 03/04/05 precedent (see STATE.md
/// `KeychainBackend` / `SampleBookInstaller`): all mutable state is guarded
/// by `OSAllocatedUnfairLock`. The protocol witness must be Sendable; the
/// state inside is non-Sendable scalars but always touched under the lock.
final class StubAuthService: AuthService, @unchecked Sendable {

    struct State {
        var appleCallCount = 0
        var shouldThrow: Error? = nil
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var appleCallCount: Int { lock.withLock { $0.appleCallCount } }

    func setShouldThrow(_ error: Error?) {
        lock.withLock { $0.shouldThrow = error }
    }

    // MARK: AuthService

    var currentUser: User? {
        get async { nil }
    }

    func signInWithApple() async throws -> User {
        lock.withLock { $0.appleCallCount += 1 }
        if let e = lock.withLock({ $0.shouldThrow }) {
            throw e
        }
        return Self.makeUser()
    }

    func signOut() async throws {}
    func deleteAccount() async throws {}

    // MARK: helpers

    private static func makeUser() -> User {
        User(
            id: UUID(),
            email: "stub@example.test",
            displayName: nil,
            avatarURL: nil,
            hasPro: false,
            createdAt: Date()
        )
    }
}

// Sentinel error for failure-path tests.
private struct TestError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Suite

@MainActor
@Suite("SignedOutViewModel")
struct SignedOutViewModelTests {

    // Test 1: Initial state is .idle, isLoading == false, errorMessage == nil.
    @Test func initialStateIsIdle() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        #expect(vm.state == .idle)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    // Test 2: signInWithApple() calls stub.signInWithApple() exactly once.
    @Test func signInWithAppleCallsService() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        await vm.signInWithApple()

        #expect(stub.appleCallCount == 1)
    }

    // Test 3: When stub throws on Apple, state becomes .error and
    // errorMessage is non-nil + non-empty.
    @Test func appleFailureSurfacesError() async throws {
        let stub = StubAuthService()
        stub.setShouldThrow(TestError(description: "siwa-failed"))
        let vm = SignedOutViewModel(authService: stub)

        await vm.signInWithApple()

        if case .error(let msg) = vm.state {
            #expect(!msg.isEmpty)
        } else {
            Issue.record("Expected .error state, got \(vm.state)")
        }
        #expect(vm.errorMessage?.isEmpty == false)
    }

    // Test 4: During an in-flight sign-in, isLoading == true.
    //
    // Gating strategy: a HangingAuthService suspends inside signInWithApple
    // forever (until released by the test). The test fires the sign-in in a
    // detached Task, yields the main actor, asserts `vm.isLoading == true`,
    // then releases the hang to let the call finish before the test exits.
    @Test func isLoadingTrueWhileInFlight() async throws {
        let hang = HangingAuthService()
        let vm = SignedOutViewModel(authService: hang)

        let task = Task { await vm.signInWithApple() }

        // Yield so the VM Task gets a chance to set state = .loading and
        // call into the service (which then suspends on the hang).
        for _ in 0..<20 {
            await Task.yield()
            if vm.isLoading { break }
        }

        #expect(vm.isLoading == true)

        hang.release()
        await task.value
    }

    // Test 5: A successful sign-in transitions to terminal .signedIn
    // (errorMessage cleared). Plan-15-quick-fix `siwa-double-fire-403`:
    // success no longer returns to .idle because the VM must keep the
    // button disabled until RootView swaps the view tree. Re-tap during
    // that window was the root cause of the 403 on the second
    // `/api/auth/sign-in/social` POST.
    @Test func successTransitionsToSignedIn() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        // First force an error...
        stub.setShouldThrow(TestError(description: "first-attempt-failed"))
        await vm.signInWithApple()
        #expect(vm.errorMessage != nil)

        // ...then a successful retry should clear the error AND park the
        // VM in the .signedIn terminal state.
        stub.setShouldThrow(nil)
        await vm.signInWithApple()
        #expect(vm.state == .signedIn)
        #expect(vm.errorMessage == nil)
        #expect(vm.isSignInButtonDisabled == true)
    }

    // Test 7 (regression for `siwa-double-fire-403`): once the first
    // `signInWithApple()` succeeds, a second invocation MUST NOT call the
    // underlying service again. Before the fix, the VM returned to .idle
    // after success, the SignedOutView button re-enabled, and a re-tap
    // during the RootView render swap produced a duplicate
    // `POST /api/auth/sign-in/social` that Better Auth rejected with 403.
    @Test func secondSignInAfterSuccessIsDropped() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        await vm.signInWithApple()
        #expect(stub.appleCallCount == 1)
        #expect(vm.state == .signedIn)

        // Simulate a stray re-tap (or programmatic re-entry) after the
        // first success. The VM must drop the call.
        await vm.signInWithApple()
        #expect(stub.appleCallCount == 1, "Second sign-in invocation after success must be dropped")
        #expect(vm.state == .signedIn)
    }

    // Test 8 (regression for `siwa-double-fire-403`): the
    // `onSignedIn` callback fires exactly once on the first successful
    // sign-in and is NOT re-fired by any subsequent invocation. This
    // closes the wire RootView uses to flip `currentUser` and mount the
    // signed-in tree.
    @Test func onSignedInFiresExactlyOnceOnSuccess() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        // Re-entrant @MainActor counter — simple Int is fine here because
        // the closure is invoked synchronously inside the VM's
        // `@MainActor`-isolated method body.
        var callbackCount = 0
        vm.onSignedIn = { _ in callbackCount += 1 }

        await vm.signInWithApple()
        #expect(callbackCount == 1)

        // Subsequent calls are dropped (Test 7) and MUST NOT re-fire the
        // callback even if a future refactor weakens the drop.
        await vm.signInWithApple()
        await vm.signInWithApple()
        #expect(callbackCount == 1, "onSignedIn must fire exactly once")
    }

    // Test 6 (regression for `signed-out-google-button-noop`): A VM
    // constructed with a nil auth service AND later injected with a real
    // service via `setAuthService(_:)` correctly routes subsequent
    // sign-in calls to the injected service.
    //
    // Background: SignedOutView used to hold a `@State` Optional VM and
    // deferred construction to `.task`. That pattern had two compounding
    // failure modes (tap-before-task, Optional-Observable tracking) that
    // produced a silent no-op on the social button in DEBUG sim builds.
    // The fix shipped here is to construct the VM eagerly with nil auth
    // and late-inject the environment value via `setAuthService(_:)`.
    // This test guards the late-injection contract so future refactors
    // don't reintroduce the silent failure. Plan 15-03 reframed this
    // around the Apple path after Google Sign-In was hard-removed.
    @Test func lateInjectedAuthServiceRoutesCalls() async throws {
        // Construct the VM with no service — mirrors `@State` eager init
        // in SignedOutView before `.task` has run.
        let vm = SignedOutViewModel(authService: nil)

        // BEFORE injection: calls bail with the "not available" error
        // (proves the nil-guard works and we haven't accidentally crashed).
        await vm.signInWithApple()
        #expect(vm.errorMessage == "Authentication is not available.")

        // Late-inject the real service — mirrors `.task` running and
        // calling `setAuthService(authService)` on first appearance.
        let stub = StubAuthService()
        vm.setAuthService(stub)

        // AFTER injection: calls route to the injected service. The
        // previous error is cleared on success; the VM parks in the
        // terminal .signedIn state (siwa-double-fire-403 regression).
        await vm.signInWithApple()
        #expect(stub.appleCallCount == 1)
        #expect(vm.state == .signedIn)
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - HangingAuthService (Test 4 helper)

/// Suspends on the first call to `signInWithApple()` until `release()` is
/// called. Lets the test observe `isLoading == true`.
final class HangingAuthService: AuthService, @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    var currentUser: User? { get async { nil } }

    func signInWithApple() async throws -> User {
        await suspendUntilReleased()
        return User(id: UUID(), email: "h@b.c", displayName: nil, avatarURL: nil, hasPro: false, createdAt: Date())
    }

    func signOut() async throws {}
    func deleteAccount() async throws {}

    func release() {
        let cont = lock.withLock { state -> CheckedContinuation<Void, Never>? in
            let c = state
            state = nil
            return c
        }
        cont?.resume()
    }

    private func suspendUntilReleased() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock { $0 = cont }
        }
    }
}
