import Foundation
import RishiCore

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
    /// Launch the voice session for `bookId`. When `initialQuote` is non-nil
    /// the voice surface opens its text-chat sheet prefilled with the quote
    /// so the user can add a question beneath it.
    func presentVoice(bookId: BookID, initialQuote: String?)
}
