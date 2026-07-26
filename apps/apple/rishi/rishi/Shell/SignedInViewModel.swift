

import SwiftUI

@MainActor
@Observable
final class SignedInViewModel {
    var selectedConversation: Conversation?
    var paywallFeature: PaywallFeature?
    var showSettings = false
    private(set) var bookHints: [BookID: Book] = [:]

    func requestPaywall(_ name: String, serverPaidActive: Bool = false) {
        if serverPaidActive,
           name != "narration_exhausted",
           name != "voice_chat_exhausted"
        {
            return
        }
        paywallFeature = PaywallFeature(name: name)
    }
    func dismissPaywall() { paywallFeature = nil }
    func present(conversation: Conversation) {
        selectedConversation = conversation
    }
    func requestSettings() { showSettings = true }
    func hint(_ book: Book) { bookHints[book.id] = book }
    func hint(for id: BookID) -> Book? { bookHints[id] }

    func performInitialLibrarySync(
        refresh: () async -> Void,
        sync: () async -> Void
    ) async {
        await refresh()
        await sync()
        await refresh()
    }
}
