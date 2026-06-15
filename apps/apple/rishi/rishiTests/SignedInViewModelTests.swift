//
//  SignedInViewModelTests.swift
//  rishiTests
//

import Testing
import RishiCore
import RishiTesting
@testable import rishi

@MainActor
@Suite("SignedInViewModel")
struct SignedInViewModelTests {

    @Test("requestPaywall sets the paywall feature by name")
    func requestPaywall() {
        let model = SignedInViewModel()
        model.requestPaywall("Read Aloud")
        #expect(model.paywallFeature?.name == "Read Aloud")
    }

    @Test("dismissPaywall clears the feature")
    func dismissPaywall() {
        let model = SignedInViewModel()
        model.requestPaywall("Voice Chat")
        model.dismissPaywall()
        #expect(model.paywallFeature == nil)
    }

    @Test("hint caches a book by id and reads it back")
    func bookHints() {
        let model = SignedInViewModel()
        let book = Book.fixture()
        model.hint(book)
        #expect(model.hint(for: book.id)?.id == book.id)
    }

    @Test("requestSettings sets the flag")
    func settings() {
        let model = SignedInViewModel()
        #expect(model.showSettings == false)
        model.requestSettings()
        #expect(model.showSettings == true)
    }

    @Test("present(conversation:) sets selectedConversation")
    func presentConversation() {
        let model = SignedInViewModel()
        let convo = Conversation.fixture()
        model.present(conversation: convo)
        #expect(model.selectedConversation?.id == convo.id)
    }
}
