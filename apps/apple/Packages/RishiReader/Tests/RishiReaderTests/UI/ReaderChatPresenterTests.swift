import Testing
import Foundation
import RishiCore
@testable import RishiReader

/// Plan 09-06 Task 2 — `ReaderChatPresenter` is the protocol seam letting the
/// reader request the chat panel without importing RishiChat (layer rule).
///
/// The app layer's `ChatPresenterImpl` (in `rishi/rishi/Chat/`) implements
/// this protocol and drives the SwiftUI sheet binding from `RootView`.
@MainActor
@Suite("ReaderChatPresenter — protocol contract", .serialized)
struct ReaderChatPresenterTests {

    /// Records every `presentChat` call so tests can assert routing without
    /// dragging SwiftUI sheets through the test runner.
    final class FakeReaderChatPresenter: ReaderChatPresenter {
        struct Call: Equatable {
            let bookId: BookID
            let initialQuote: String?
        }
        var calls: [Call] = []

        func presentChat(bookId: BookID, initialQuote: String?) {
            calls.append(Call(bookId: bookId, initialQuote: initialQuote))
        }
    }

    @Test("FakeReaderChatPresenter records a (bookId, nil) call for the toolbar action")
    func toolbarActionRecordsNilQuote() {
        let presenter = FakeReaderChatPresenter()
        let bookId: BookID = UUID()

        presenter.presentChat(bookId: bookId, initialQuote: nil)

        #expect(presenter.calls == [.init(bookId: bookId, initialQuote: nil)])
    }

    @Test("FakeReaderChatPresenter records the quote for the selection action")
    func selectionActionRecordsQuote() {
        let presenter = FakeReaderChatPresenter()
        let bookId: BookID = UUID()
        let quote = "It was the best of times, it was the worst of times."

        presenter.presentChat(bookId: bookId, initialQuote: quote)

        #expect(presenter.calls.count == 1)
        #expect(presenter.calls.first?.bookId == bookId)
        #expect(presenter.calls.first?.initialQuote == quote)
    }

    @Test("Multiple presentChat calls accumulate in order")
    func presentChatAccumulates() {
        let presenter = FakeReaderChatPresenter()
        let bookId: BookID = UUID()

        presenter.presentChat(bookId: bookId, initialQuote: nil)
        presenter.presentChat(bookId: bookId, initialQuote: "first quote")
        presenter.presentChat(bookId: bookId, initialQuote: "second quote")

        #expect(presenter.calls.count == 3)
        #expect(presenter.calls[1].initialQuote == "first quote")
        #expect(presenter.calls[2].initialQuote == "second quote")
    }
}
