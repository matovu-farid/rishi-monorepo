import Foundation
import RishiCore

/// Protocol seam letting the reader request the chat panel without
/// depending on RishiChat.
///
/// **Layer rule:** Feature packages do not import sibling Features. The
/// reader screens accept an optional `(any ReaderChatPresenter)?` and call
/// it from their toolbar chat button + selection "Ask about this" action.
/// The concrete impl (`ChatPresenterImpl`) lives in the rishi app target
/// (`apps/apple/rishi/rishi/Chat/`) and drives a SwiftUI sheet binding
/// from `RootView`.
///
/// When `chatPresenter == nil` is injected (tests, previews, or any future
/// reader call site that doesn't want chat), the toolbar chat button and
/// the "Ask about this" menu item are HIDDEN — there is no orphan UI.
@MainActor
public protocol ReaderChatPresenter: AnyObject {
    /// Request the chat sheet for `bookId`. When `initialQuote` is non-nil
    /// the chat composer is prefilled with `> {quote}\n\n` so the user can
    /// add a question beneath it (CHAT-05).
    func presentChat(bookId: BookID, initialQuote: String?)
}
