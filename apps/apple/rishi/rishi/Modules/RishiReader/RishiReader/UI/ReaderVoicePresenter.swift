import Foundation


/// Live reading context captured at the moment the reader launches voice.
///
/// **Layer rule:** RishiReader must NOT import RishiCore / RishiVoice, so this
/// is a reader-local value type. The app-layer adapter (`ReaderVoiceEntry`)
/// maps it onto `RishiAPI.BookContextSnapshot` / `BookOutlineDTO` before
/// handing it to the voice session.
///
/// `title` + `author` are ALWAYS populated (from `viewModel.book`) so the
/// worker's system prompt can render book identity ("what is this book
/// about"). The remaining fields are best-effort: a session can start before
/// any heavy text extraction completes, so `pageText` /
/// `activeParagraphText` / EPUB `chapters` may be nil/empty in v1.
public struct ReaderVoiceContext: Sendable, Equatable {
    /// Book title. Always set.
    public let title: String
    /// Book author, when known.
    public let author: String?
    /// Flat chapter/outline titles in reading order. Empty when the reader
    /// has no cheap outline to surface (e.g. EPUB before TOC is loaded).
    public let chapters: [String]
    /// 1-based current page, when the reader has an integer page model
    /// (PDF). `nil` for reflowable EPUB where there is no fixed page.
    public let currentPage: Int?
    /// Visible page text, best-effort. `nil` when not cheaply available.
    public let pageText: String?
    /// The paragraph the user is actively reading, best-effort.
    public let activeParagraphText: String?

    public init(
        title: String,
        author: String?,
        chapters: [String],
        currentPage: Int?,
        pageText: String?,
        activeParagraphText: String?
    ) {
        self.title = title
        self.author = author
        self.chapters = chapters
        self.currentPage = currentPage
        self.pageText = pageText
        self.activeParagraphText = activeParagraphText
    }

    /// Seed a context from a `Book` identity only — title + author set, every
    /// finer-grained signal left nil/empty. Screens start from this and fill
    /// in whatever page-level context is cheaply available.
    public init(book: Book) {
        self.init(
            title: book.title,
            author: book.author,
            chapters: [],
            currentPage: nil,
            pageText: nil,
            activeParagraphText: nil
        )
    }
}

/// Protocol seam letting the reader launch the voice session without
/// depending on RishiVoice.
///
/// **Layer rule:** Feature packages do not import sibling Features. The
/// reader screens accept an optional `(any ReaderVoicePresenter)?` and call
/// it from their toolbar voice button + selection "Ask about this" action.
/// The concrete impl lives in the rishi app target and drives a SwiftUI
/// sheet binding from `RootView`.
///
/// Voice is the primary AI surface: tapping the toolbar button starts a
/// voice session. When `initialQuote` is non-nil (the "Ask about this"
/// text-selection affordance), the quote routes into a text-chat sheet
/// hosted INSIDE the voice surface so the user can ask about the passage.
///
/// When `voicePresenter == nil` is injected (tests, previews, or any future
/// reader call site that doesn't want voice), the toolbar voice button and
/// the "Ask about this" menu item are HIDDEN — there is no orphan UI.
@MainActor
public protocol ReaderVoicePresenter: AnyObject {
    /// Launch the voice session for `bookId`, threading the reader's live
    /// `context` (book identity + best-effort page signals) through to the
    /// model. When `initialQuote` is non-nil the voice surface opens its
    /// text-chat sheet prefilled with the quote so the user can add a
    /// question beneath it.
    func presentVoice(bookId: BookID, context: ReaderVoiceContext, initialQuote: String?)
}
