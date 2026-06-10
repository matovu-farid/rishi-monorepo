//
//  SignedOutViewModelTests.swift
//  rishiTests
//
//  Quick-SXI — Swift Testing suite proving the SignedOutViewModel state
//  machine. Stub AuthService records call counts and can be configured
//  to throw or to block on a CheckedContinuation so the test can observe
//  the in-flight loading state.
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
        var googleCallCount = 0
        var shouldThrow: Error? = nil
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var appleCallCount: Int { lock.withLock { $0.appleCallCount } }
    var googleCallCount: Int { lock.withLock { $0.googleCallCount } }

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

    func signInWithGoogle() async throws -> User {
        lock.withLock { $0.googleCallCount += 1 }
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
        #expect(stub.googleCallCount == 0)
    }

    // Test 3: signInWithGoogle() calls stub.signInWithGoogle() exactly once.
    @Test func signInWithGoogleCallsService() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        await vm.signInWithGoogle()

        #expect(stub.googleCallCount == 1)
        #expect(stub.appleCallCount == 0)
    }

    // Test 4: When stub throws on Apple, state becomes .error and
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

    // Test 5: When stub throws on Google, state becomes .error and
    // errorMessage is non-nil + non-empty.
    @Test func googleFailureSurfacesError() async throws {
        let stub = StubAuthService()
        stub.setShouldThrow(TestError(description: "google-failed"))
        let vm = SignedOutViewModel(authService: stub)

        await vm.signInWithGoogle()

        if case .error(let msg) = vm.state {
            #expect(!msg.isEmpty)
        } else {
            Issue.record("Expected .error state, got \(vm.state)")
        }
        #expect(vm.errorMessage?.isEmpty == false)
    }

    // Test 6: During an in-flight sign-in, isLoading == true.
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

    // Test 7: A successful sign-in resets state to .idle (errorMessage cleared).
    @Test func successResetsToIdle() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        // First force an error...
        stub.setShouldThrow(TestError(description: "first-attempt-failed"))
        await vm.signInWithApple()
        #expect(vm.errorMessage != nil)

        // ...then a successful retry should clear the error.
        stub.setShouldThrow(nil)
        await vm.signInWithApple()
        #expect(vm.state == .idle)
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - HangingAuthService (Test 6 helper)

/// Suspends on the first call to `signInWithApple()` / `signInWithGoogle()`
/// until `release()` is called. Lets the test observe `isLoading == true`.
final class HangingAuthService: AuthService, @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    var currentUser: User? { get async { nil } }

    func signInWithApple() async throws -> User {
        await suspendUntilReleased()
        return User(id: UUID(), email: "h@b.c", displayName: nil, avatarURL: nil, hasPro: false, createdAt: Date())
    }

    func signInWithGoogle() async throws -> User {
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
