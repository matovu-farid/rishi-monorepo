import Testing
import Foundation
@testable import RishiChat
import RishiCore

@Suite("RishiChat package smoke")
struct PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiChat.version == "0.1.0-scaffold")
    }

    @Test("RishiCore Conversation is reachable from the test target")
    func rishiCoreConversationIsReachable() {
        let convo = Conversation(
            userId: UUID(),
            bookId: UUID(),
            title: "Smoke"
        )
        #expect(convo.title == "Smoke")
        #expect(convo.bookId != nil)
    }

    @Test("RishiCore Message is reachable with .user role")
    func rishiCoreMessageIsReachable() {
        let msg = Message(
            conversationId: UUID(),
            role: .user,
            content: "hi"
        )
        #expect(msg.role == .user)
        #expect(msg.content == "hi")
    }

    @Test("ChatEvent cases are constructible — proves protocol seam links")
    func chatEventIsReachable() {
        let token = ChatEvent.token("hi")
        let done = ChatEvent.completed
        #expect(token == .token("hi"))
        #expect(done == .completed)
    }
}
