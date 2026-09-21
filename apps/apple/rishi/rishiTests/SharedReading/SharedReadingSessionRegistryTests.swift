import Foundation
import Testing

@testable import rishi

@MainActor
@Suite("Shared reading session registry", .serialized)
struct SharedReadingSessionRegistryTests {
    private final class Handle: SharedReadingSessionRegistryHandle, @unchecked Sendable {
        let id = UUID()
        private(set) var cancelled = 0
        private(set) var left = 0

        func cancelLocally() async { cancelled += 1 }
        func leaveRemotely() async { left += 1 }
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
}
