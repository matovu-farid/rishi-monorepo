

import Testing
import Foundation

@testable import rishi

@MainActor
@Suite("DeepLinkRouter")
struct DeepLinkRouterTests {

    let router = DeepLinkRouter()

    @Test("Custom-scheme auth callback")
    func authCallbackCustomScheme() {
        let url = URL(string: "rishi://auth/callback?token=xyz")!
        #expect(router.route(url) == .authCallback(token: "xyz"))
    }

    @Test("Custom-scheme share redeem")
    func shareRedeemCustomScheme() {
        let url = URL(string: "rishi://sharing/join?token=abc")!
        #expect(router.route(url) == .shareRedeem(token: "abc"))
    }

    @Test("Universal Link book open")
    func universalBookOpen() {
        let id = UUID()
        let url = URL(string: "https://rishi.fidexa.org/app/book/\(id.uuidString)")!
        #expect(router.route(url) == .openBook(id))
    }

    @Test("Universal Link conversation open")
    func universalConversationOpen() {
        let id = UUID()
        let url = URL(string: "https://rishi.fidexa.org/app/conversation/\(id.uuidString)")!
        #expect(router.route(url) == .openConversation(id))
    }

    @Test("Universal Link auth callback")
    func universalAuthCallback() {
        let url = URL(string: "https://rishi.fidexa.org/auth/callback?token=xyz")!
        #expect(router.route(url) == .authCallback(token: "xyz"))
    }

    @Test("Universal Link share redeem")
    func universalShareRedeem() {
        let url = URL(string: "https://rishi.fidexa.org/sharing/join?token=abc")!
        #expect(router.route(url) == .shareRedeem(token: "abc"))
    }

    @Test("Foreign host → unknown")
    func foreignHostUnknown() {
        let url = URL(string: "https://other-domain.com/app/book/x")!
        #expect(router.route(url) == .unknown)
    }

    @Test("Malformed UUID → unknown")
    func malformedUUID() {
        let url = URL(string: "https://rishi.fidexa.org/app/book/not-a-uuid")!
        #expect(router.route(url) == .unknown)
    }

    @Test("Empty rishi:// URL → unknown")
    func emptyURL() {
        let url = URL(string: "rishi://")!
        #expect(router.route(url) == .unknown)
    }

    @Test("Unsupported scheme → unknown")
    func unsupportedScheme() {
        let url = URL(string: "ftp://rishi.fidexa.org/app/book/x")!
        #expect(router.route(url) == .unknown)
    }

    @Test("Universal Link malformed conversation UUID → unknown")
    func malformedConversationUUID() {
        let url = URL(string: "https://rishi.fidexa.org/app/conversation/not-a-uuid")!
        #expect(router.route(url) == .unknown)
    }

    @Test("Custom-scheme book open via UUID path")
    func customSchemeBookOpen() {
        let id = UUID()
        let url = URL(string: "rishi://book/\(id.uuidString)")!
        #expect(router.route(url) == .openBook(id))
    }

    @Test("Custom-scheme conversation open via UUID path")
    func customSchemeConversationOpen() {
        let id = UUID()
        let url = URL(string: "rishi://conversation/\(id.uuidString)")!
        #expect(router.route(url) == .openConversation(id))
    }

    @Test("Host casing is normalised")
    func universalHostCaseInsensitive() {
        let id = UUID()
        let url = URL(string: "https://RISHI.FIDEXA.ORG/app/book/\(id.uuidString)")!
        #expect(router.route(url) == .openBook(id))
    }
}
