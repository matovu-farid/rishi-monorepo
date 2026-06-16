import Testing
import Foundation
import RishiCore
@testable import RishiReader

/// `ReaderVoicePresenter` is the protocol seam letting the reader request the
/// voice panel without importing RishiVoice (layer rule).
///
/// The app layer's voice host implements this protocol and drives the SwiftUI
/// sheet binding from `RootView`. The `initialQuote` parameter routes a
/// text-selection ("Ask about this") quote into the text-chat sheet hosted
/// inside the voice surface.
@MainActor
@Suite("ReaderVoicePresenter — protocol contract", .serialized)
struct ReaderVoicePresenterTests {

    /// Records every `presentVoice` call so tests can assert routing without
    /// dragging SwiftUI sheets through the test runner.
    final class FakeReaderVoicePresenter: ReaderVoicePresenter {
        struct Call: Equatable {
            let bookId: BookID
            let initialQuote: String?
        }
        var calls: [Call] = []

        func presentVoice(bookId: BookID, initialQuote: String?) {
            calls.append(Call(bookId: bookId, initialQuote: initialQuote))
        }
    }

    @Test("FakeReaderVoicePresenter records a (bookId, nil) call for the toolbar action")
    func toolbarActionRecordsNilQuote() {
        let presenter = FakeReaderVoicePresenter()
        let bookId: BookID = UUID()

        presenter.presentVoice(bookId: bookId, initialQuote: nil)

        #expect(presenter.calls == [.init(bookId: bookId, initialQuote: nil)])
    }

    @Test("FakeReaderVoicePresenter records the quote for the selection action")
    func selectionActionRecordsQuote() {
        let presenter = FakeReaderVoicePresenter()
        let bookId: BookID = UUID()
        let quote = "It was the best of times, it was the worst of times."

        presenter.presentVoice(bookId: bookId, initialQuote: quote)

        #expect(presenter.calls.count == 1)
        #expect(presenter.calls.first?.bookId == bookId)
        #expect(presenter.calls.first?.initialQuote == quote)
    }

    @Test("Multiple presentVoice calls accumulate in order")
    func presentVoiceAccumulates() {
        let presenter = FakeReaderVoicePresenter()
        let bookId: BookID = UUID()

        presenter.presentVoice(bookId: bookId, initialQuote: nil)
        presenter.presentVoice(bookId: bookId, initialQuote: "first quote")
        presenter.presentVoice(bookId: bookId, initialQuote: "second quote")

        #expect(presenter.calls.count == 3)
        #expect(presenter.calls[1].initialQuote == "first quote")
        #expect(presenter.calls[2].initialQuote == "second quote")
    }
}
