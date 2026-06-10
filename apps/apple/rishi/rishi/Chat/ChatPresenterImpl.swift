//
//  ChatPresenterImpl.swift
//  rishi
//
//  Phase 9 Plan 09-06 — app-layer state holder driving the chat sheet
//  binding from RootView. Satisfies the `ReaderChatPresenter` protocol
//  (RishiReader) so the reader screens can request the chat panel
//  without importing RishiChat (layer rule).
//

import Foundation
import RishiCore
import RishiReader

/// Stateful presenter retained for the app lifetime by ``AppDependencies``.
/// Reader screens call ``presentChat(bookId:initialQuote:)``; RootView
/// observes ``pendingPresentation`` and mounts a ``ChatPanelView`` sheet
/// resolving the viewmodel asynchronously through
/// ``AppDependencies/makeChatPanelViewModel(bookId:)``.
@MainActor
@Observable
final class ChatPresenterImpl: ReaderChatPresenter {

    /// Active sheet request, or `nil` when no chat sheet is presented.
    /// Identifiable + Equatable so SwiftUI `.sheet(item:)` can drive
    /// mount / dismiss on identity changes.
    struct Pending: Identifiable, Equatable {
        let id: UUID = UUID()
        let bookId: BookID
        let initialQuote: String?
    }

    var pendingPresentation: Pending? = nil

    nonisolated init() {}

    func presentChat(bookId: BookID, initialQuote: String?) {
        pendingPresentation = Pending(bookId: bookId, initialQuote: initialQuote)
    }

    /// RootView calls this from the sheet's `onDismiss` to clear the
    /// presentation so a future `presentChat` re-mints a fresh identity.
    func clear() {
        pendingPresentation = nil
    }
}
