import Foundation
import Testing

@testable import rishi

@MainActor
@Suite("Shared reading session registry", .serialized)
struct SharedReadingSessionRegistryTests {
    @MainActor
    private class Handle: SharedReadingSessionRegistryHandle {
        let id = UUID()
        private(set) var cancelled = 0
        private(set) var left = 0

        func cancelLocally() async { cancelled += 1 }
        func leaveRemotely() async { left += 1 }
    }

    private final class NeverLeavingHandle: Handle {
        override func leaveRemotely() async {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
    }

    @Test("drain cancels local resources immediately and leaves registered account sessions")
    func drainsAccountSessions() async {
        let account = UUID()
        let handle = Handle()
        let registry = SharedReadingSessionRegistry()
        registry.register(handle, accountID: account)

        await registry.drain(accountID: account)

        #expect(handle.cancelled == 1)
        #expect(handle.left == 1)
        #expect(registry.activeHandleCount == 0)
    }

    @Test("a stale account callback cannot drain a new account session")
    func generationGuardsDelayedCallbacks() async {
        let oldAccount = UUID()
        let newAccount = UUID()
        let oldHandle = Handle()
        let newHandle = Handle()
        let registry = SharedReadingSessionRegistry()
        let token = registry.register(oldHandle, accountID: oldAccount)
        registry.register(newHandle, accountID: newAccount)

        await registry.drain(accountID: oldAccount)
        registry.unregister(token)

        #expect(newHandle.cancelled == 0)
        #expect(newHandle.left == 0)
        #expect(registry.activeHandleCount == 1)
    }

    @Test("drain cancels a never-returning remote leave at its deadline")
    func drainHonorsRemoteLeaveDeadline() async {
        let account = UUID()
        let handle = NeverLeavingHandle()
        let registry = SharedReadingSessionRegistry()
        registry.register(handle, accountID: account)

        await registry.drain(accountID: account, deadline: .milliseconds(20))

        #expect(handle.cancelled == 1)
        #expect(registry.activeHandleCount == 0)
    }

    @Test("an old registration is invalid after its account drains")
    func drainInvalidatesDelayedOldAccountCallbacks() async {
        let account = UUID()
        let handle = Handle()
        let registry = SharedReadingSessionRegistry()
        let registration = registry.register(handle, accountID: account)

        await registry.drain(accountID: account)

        #expect(registry.isCurrent(registration) == false)
    }
}
