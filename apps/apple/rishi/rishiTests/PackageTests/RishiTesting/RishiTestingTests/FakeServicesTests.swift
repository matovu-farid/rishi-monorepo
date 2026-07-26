@testable import rishi
import Foundation
import Testing



@Suite("Fake services")
struct FakeServicesTests {

    @Test func fakeAuthServiceRecordsCalls() async throws {
        let auth = FakeAuthService()
        #expect(await auth.currentUser == nil)
        let user = try await auth.signInWithApple()
        #expect(user.email?.contains("siwa.fixture") == true)
        #expect(await auth.signInAppleCallCount == 1)
        try await auth.signOut()
        #expect(await auth.currentUser == nil)
        #expect(await auth.signOutCallCount == 1)
        try await auth.deleteAccount()
        #expect(await auth.deleteAccountCallCount == 1)
    }

    @Test func fakeChatServiceStreamsConfiguredEvents() async throws {
        let chat = FakeChatService(events: [.token("a"), .token("b"), .completed])
        var received: [ChatEvent] = []
        for try await ev in chat.stream(query: "?", bookId: nil) {
            received.append(ev)
        }
        #expect(received == [.token("a"), .token("b"), .completed])
        #expect(chat.streamCallCount == 1)
    }

    @Test func mockWorkerClientConstructs() {
        let client: any WorkerAPI = MockWorkerClient()
        _ = client
    }
}
