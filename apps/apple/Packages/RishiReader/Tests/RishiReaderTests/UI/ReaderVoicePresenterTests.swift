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
            let context: ReaderVoiceContext
            let initialQuote: String?
        }
        var calls: [Call] = []

        func presentVoice(bookId: BookID, context: ReaderVoiceContext, initialQuote: String?) {
            calls.append(Call(bookId: bookId, context: context, initialQuote: initialQuote))
        }
    }

    /// A minimal context for tests that only care about routing.
    private func ctx(title: String = "Moby Dick", author: String? = "Herman Melville") -> ReaderVoiceContext {
        ReaderVoiceContext(
            title: title,
            author: author,
            chapters: [],
            currentPage: nil,
            pageText: nil,
            activeParagraphText: nil
        )
    }

    @Test("FakeReaderVoicePresenter records a (bookId, context, nil) call for the toolbar action")
    func toolbarActionRecordsNilQuote() {
        let presenter = FakeReaderVoicePresenter()
        let bookId: BookID = UUID()
        let context = ctx()

        presenter.presentVoice(bookId: bookId, context: context, initialQuote: nil)

        #expect(presenter.calls == [.init(bookId: bookId, context: context, initialQuote: nil)])
        #expect(presenter.calls.first?.context.title == "Moby Dick")
        #expect(presenter.calls.first?.context.author == "Herman Melville")
    }

    @Test("FakeReaderVoicePresenter records the quote for the selection action")
    func selectionActionRecordsQuote() {
        let presenter = FakeReaderVoicePresenter()
        let bookId: BookID = UUID()
        let quote = "It was the best of times, it was the worst of times."

        presenter.presentVoice(bookId: bookId, context: ctx(), initialQuote: quote)

        #expect(presenter.calls.count == 1)
        #expect(presenter.calls.first?.bookId == bookId)
        #expect(presenter.calls.first?.initialQuote == quote)
    }

    @Test("Multiple presentVoice calls accumulate in order")
    func presentVoiceAccumulates() {
        let presenter = FakeReaderVoicePresenter()
        let bookId: BookID = UUID()

        presenter.presentVoice(bookId: bookId, context: ctx(), initialQuote: nil)
        presenter.presentVoice(bookId: bookId, context: ctx(), initialQuote: "first quote")
        presenter.presentVoice(bookId: bookId, context: ctx(), initialQuote: "second quote")

        #expect(presenter.calls.count == 3)
        #expect(presenter.calls[1].initialQuote == "first quote")
        #expect(presenter.calls[2].initialQuote == "second quote")
    }

    // MARK: - ReaderVoiceContext value-type contract

    @Test("ReaderVoiceContext carries title/author/chapters/page fields verbatim")
    func contextCarriesAllFields() {
        let context = ReaderVoiceContext(
            title: "How to Prove It",
            author: "Daniel Velleman",
            chapters: ["Sentential Logic", "Quantificational Logic"],
            currentPage: 12,
            pageText: "A proof is a careful argument.",
            activeParagraphText: "A proof is a careful argument."
        )

        #expect(context.title == "How to Prove It")
        #expect(context.author == "Daniel Velleman")
        #expect(context.chapters == ["Sentential Logic", "Quantificational Logic"])
        #expect(context.currentPage == 12)
        #expect(context.pageText == "A proof is a careful argument.")
        #expect(context.activeParagraphText == "A proof is a careful argument.")
    }

    @Test("ReaderVoiceContext(book:) seeds title+author from the Book, others nil/empty")
    func contextFromBookSeedsIdentity() {
        let book = Book(
            id: UUID(),
            userId: UUID(),
            title: "Frankenstein",
            author: "Mary Shelley",
            formatType: .epub,
            fileURL: "frankenstein.epub"
        )

        let context = ReaderVoiceContext(book: book)

        #expect(context.title == "Frankenstein")
        #expect(context.author == "Mary Shelley")
        #expect(context.chapters.isEmpty)
        #expect(context.currentPage == nil)
        #expect(context.pageText == nil)
        #expect(context.activeParagraphText == nil)
    }
}
