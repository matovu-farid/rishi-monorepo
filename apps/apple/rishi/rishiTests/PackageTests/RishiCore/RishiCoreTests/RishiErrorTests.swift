@testable import rishi
import Foundation
import Testing


@Suite("RishiError")
struct RishiErrorTests {

    @Test func unauthenticatedDescriptionMentionsSignedIn() {
        let err: RishiError = .unauthenticated
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("signed in"))
    }

    @Test func networkFailureWrapsUnderlying() {
        let urlError = URLError(.notConnectedToInternet)
        let err: RishiError = .networkFailure(urlError)
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("Network error"))
    }

    @Test func persistenceCarriesMessage() {
        let err: RishiError = .persistence("disk full")
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("disk full"))
    }

    @Test func notFoundHasDescription() {
        let err: RishiError = .notFound
        #expect(err.errorDescription != nil)
    }

    @Test func subscriptionMentionsRequirement() {
        let err: RishiError = .subscription(.pro)
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("pro"))
    }

    @Test func cancelledHasDescription() {
        let err: RishiError = .cancelled
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("cancelled"))
    }
}
