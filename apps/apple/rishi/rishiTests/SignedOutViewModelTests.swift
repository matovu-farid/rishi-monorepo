














import Foundation
import Testing
import os

@testable import rishi







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

    

    private static func makeUser() -> User {
        User(
            id: UUID(),
            email: "stub@example.test",
            name: nil,
        )
    }
}


private struct TestError: Error, CustomStringConvertible {
    let description: String
}



@MainActor
@Suite("SignedOutViewModel")
struct SignedOutViewModelTests {

    
    @Test func initialStateIsIdle() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        #expect(vm.state == .idle)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    
    @Test func signInWithAppleCallsService() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        await vm.signInWithApple()

        #expect(stub.appleCallCount == 1)
    }

    
    
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

    
    
    
    
    
    
    @Test func isLoadingTrueWhileInFlight() async throws {
        let hang = HangingAuthService()
        let vm = SignedOutViewModel(authService: hang)

        let task = Task { await vm.signInWithApple() }

        
        
        for _ in 0..<20 {
            await Task.yield()
            if vm.isLoading { break }
        }

        #expect(vm.isLoading == true)

        hang.release()
        await task.value
    }

    
    
    
    
    
    
    @Test func successTransitionsToSignedIn() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        
        stub.setShouldThrow(TestError(description: "first-attempt-failed"))
        await vm.signInWithApple()
        #expect(vm.errorMessage != nil)

        
        
        stub.setShouldThrow(nil)
        await vm.signInWithApple()
        #expect(vm.state == .signedIn)
        #expect(vm.errorMessage == nil)
        #expect(vm.isSignInButtonDisabled == true)
    }

    
    
    
    
    
    
    @Test func secondSignInAfterSuccessIsDropped() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        await vm.signInWithApple()
        #expect(stub.appleCallCount == 1)
        #expect(vm.state == .signedIn)

        
        
        await vm.signInWithApple()
        #expect(stub.appleCallCount == 1, "Second sign-in invocation after success must be dropped")
        #expect(vm.state == .signedIn)
    }

    
    
    
    
    
    @Test func onSignedInFiresExactlyOnceOnSuccess() async throws {
        let stub = StubAuthService()
        let vm = SignedOutViewModel(authService: stub)

        
        
        
        var callbackCount = 0
        vm.onSignedIn = { _ in callbackCount += 1 }

        await vm.signInWithApple()
        #expect(callbackCount == 1)

        
        
        await vm.signInWithApple()
        await vm.signInWithApple()
        #expect(callbackCount == 1, "onSignedIn must fire exactly once")
    }

    
    
    
    
    
    
    
    
    
    
    
    
    
    
    @Test func lateInjectedAuthServiceRoutesCalls() async throws {
        
        
        let vm = SignedOutViewModel(authService: nil)

        
        
        await vm.signInWithApple()
        #expect(vm.errorMessage == "Authentication is not available.")

        
        
        let stub = StubAuthService()
        vm.setAuthService(stub)

        
        
        
        await vm.signInWithApple()
        #expect(stub.appleCallCount == 1)
        #expect(vm.state == .signedIn)
        #expect(vm.errorMessage == nil)
    }
}





final class HangingAuthService: AuthService, @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    var currentUser: User? { get async { nil } }

    func signInWithApple() async throws -> User {
        await suspendUntilReleased()
        return User(id: UUID(), email: "h@b.c", name: nil)
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
