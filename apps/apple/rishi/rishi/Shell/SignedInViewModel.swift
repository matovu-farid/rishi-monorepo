//
//  SignedInViewModel.swift
//  rishi
//
//  Presentation state for the signed-in shell: the cross-cutting modal
//  triggers children raise (paywall, conversation sheet, settings) plus the
//  transient book-hint cache used to paint reader first-frames without a DB
//  round-trip. View-free, so it is unit-testable.
//

import SwiftUI
import RishiCore
import RishiChat

/// Presentation state for the signed-in shell: the cross-cutting modal
/// triggers children raise (paywall, conversation sheet, settings) plus the
/// transient book-hint cache used to paint reader first-frames without a DB
/// round-trip. View-free, so it is unit-testable.
@MainActor
@Observable
final class SignedInViewModel {
    var selectedConversation: Conversation?
    var paywallFeature: PaywallFeature?
    var showSettings = false
    private(set) var bookHints: [BookID: Book] = [:]

    func requestPaywall(_ name: String) { paywallFeature = PaywallFeature(name: name) }
    func dismissPaywall() { paywallFeature = nil }
    func present(conversation: Conversation) { selectedConversation = conversation }
    func requestSettings() { showSettings = true }
    func hint(_ book: Book) { bookHints[book.id] = book }
    func hint(for id: BookID) -> Book? { bookHints[id] }

    /// Drives the initial library sync when the signed-in shell appears
    /// (fresh sign-in, cold launch with an existing session, or account
    /// switch). The sync engine's `runOnce()` is otherwise only triggered by
    /// BGTask / silent push / manual "Sync Now", so without this a fresh
    /// device would show an empty library until a background wave happened to
    /// fire. Shows cached rows first (instant), pulls the remote library, then
    /// re-reads the local store so freshly-synced books appear.
    func performInitialLibrarySync(
        refresh: () async -> Void,
        sync: () async -> Void
    ) async {
        await refresh()
        await sync()
        await refresh()
    }
}
