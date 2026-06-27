import RishiChat
import RishiCore
import SwiftUI

@MainActor
@Observable
final class SignedInViewModel {
    var selectedConversation: Conversation?
    var paywallFeature: PaywallFeature?
    var showSettings = false
    private(set) var bookHints: [BookID: Book] = [:]

    func requestPaywall(_ name: String) {
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
