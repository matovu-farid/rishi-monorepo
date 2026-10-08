

import SwiftUI


@MainActor
@Observable
final class SignedInViewModel {
    var selectedConversation: Conversation?
    var paywallFeature: PaywallFeature?
    var showSettings = false
    private(set) var bookHints: [BookID: Book] = [:]
    func requestPaywall(_ request: PaywallRequest, serverPaidActive: Bool = false) {
        guard request.shouldPresent(serverPaidActive: serverPaidActive) else { return }
        paywallFeature = PaywallFeature(request: request)
    }
    func dismissPaywall() { paywallFeature = nil }
    func present(conversation: Conversation) {
        selectedConversation = conversation
    }
    func requestSettings() { showSettings = true }
    func hint(_ book: Book) { bookHints[book.id] = book }
    func hint(for id: BookID) -> Book? { bookHints[id] }


}
