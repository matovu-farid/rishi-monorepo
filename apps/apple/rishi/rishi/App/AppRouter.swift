//
//  AppRouter.swift
//  rishi
//
//  Extracted from RootView (refactor — Phase 29+).
//
//  Owns:
//    - The library NavigationStack path (was RootView.libraryPath @State).
//    - Deep-link dispatch (was RootView.onOpenURL body).
//    - Scene-state encode/decode (was restoreSceneState / persistSceneState).
//    - showLibraryRoot / showConversations navigation helpers.
//
//  Note: selectedTab was removed — the app unified on a single Library home
//  (commit cf722170c). persistCells() still writes a hardcoded .library value
//  to the @SceneStorage tab cell for schema continuity with existing installs.
//
//  Side effects that require RootView-owned state (selectedConversation,
//  libraryViewModel, bookHints) are forwarded via closures threaded at
//  construction time so AppRouter stays decoupled from RootView internals
//  and from AppDependencies directly.
//

import SwiftUI
import RishiCore
import RishiReader

// MARK: - ConversationsRoute (moved here so AppRouter can append it)

/// Navigation marker pushed onto the Library `NavigationStack` to show the
/// conversations list on compact-width devices where there is no tab bar.
/// A value type with no payload — there is only ever one conversations list.
struct ConversationsRoute: Hashable {}

// MARK: - AppRouter

@MainActor
@Observable
final class AppRouter {

    // MARK: Observed state

    /// Library NavigationStack path. Bind as `Bindable(router).path`.
    var path: NavigationPath = NavigationPath()

    // Note: `selectedTab` has been removed. The app unified on a single
    // Library home (commit cf722170c); the tab is always `.library`. The
    // `persistCells()` tab cell is hardcoded to `.library` for storage-schema
    // continuity with existing installs, but there is nothing live to round-trip.

    // MARK: Private helpers

    private let deepLinks = DeepLinkRouter()

    // MARK: Side-effect callbacks

    /// Called when a `.openBook` deep link resolves to a `Book`. The caller
    /// (RootView) stores the hint in `bookHints` and appends the route.
    /// `AppRouter` writes the resolved route onto `path` itself and invokes
    /// this callback with the book so the call site can populate `bookHints`.
    var onBookResolved: ((Book) -> Void)?

    /// Called when a `.openConversation` deep link resolves to a
    /// `Conversation`. RootView shows it in the `selectedConversation` sheet.
    var onConversationResolved: ((Conversation) -> Void)?

    /// Called for `.unknown` deep links that are `isFileURL` (share-sheet /
    /// Files import). RootView owns `importCoordinator` and `libraryViewModel`.
    var onFileURL: ((URL) -> Void)?

    // MARK: - Deep-link dispatch

    /// Handles any inbound URL (custom `rishi://` scheme or Universal Link).
    /// Async cases (book, conversation) spawn a `Task` and invoke the
    /// appropriate callback on the main actor when the DB lookup resolves.
    ///
    /// - Parameter url:              The URL passed by the system `.onOpenURL` modifier.
    /// - Parameter bookStore:        Resolves book IDs from the DB. Pass `nil` to
    ///                               no-op `.openBook` (e.g. in tests that only verify
    ///                               sync-path mutations).
    /// - Parameter conversationStore: Resolves conversation IDs from the DB. Pass `nil`
    ///                               to no-op `.openConversation`.
    func handle(
        url: URL,
        bookStore: (any BookStore)?,
        conversationStore: (any ConversationStore)?
    ) {
        let destination = deepLinks.route(url)
        switch destination {
        case .authCallback:
            // Phase 3's ASWebAuthenticationSession owns its own callback
            // capture for Google OAuth, and SiwaPresenter handles SIWA
            // natively. The Universal-Link variant of the callback is a
            // v1.1 nice-to-have (e.g. mail-based magic link) — for v1
            // we no-op rather than introduce a half-wired token consumer
            // on RishiAuth.AuthService.
            break

        case .shareRedeem(let token):
            // Not yet wired into RishiCore. Silently no-op so taps from
            // future share emails don't dead-end on production builds.
            _ = token

        case .openBook(let bookId):
            guard let bookStore else { return }
            // KEEP: resolve deep-linked book from the DB; MainActor store access
            Task {
                let book: Book? = try? await bookStore.book(bookId)
                guard let book else { return }
                // Cache hint in RootView for zero-flash first paint.
                onBookResolved?(book)
                // Push a fresh single-entry path so the reader is at depth 1.
                var p = NavigationPath()
                p.append(ReaderRoute.route(for: book))
                path = p
            }

        case .openConversation(let conversationId):
            guard let conversationStore else { return }
            // KEEP: resolve deep-linked conversation from the DB; MainActor store access
            Task {
                let convo: Conversation? = try? await conversationStore.conversation(conversationId)
                guard let convo else { return }
                onConversationResolved?(convo)
            }

        case .unknown:
            // Legacy path — `file://` imports from the Files app /
            // share-sheet still arrive here. Other unknown URLs are ignored.
            if url.isFileURL {
                onFileURL?(url)
            }
        }
    }

    // MARK: - Navigation helpers

    /// Reset the Library stack to root (Library home screen, no pushed routes).
    func showLibraryRoot() {
        path = NavigationPath()
    }

    /// Push the conversations list onto the Library NavigationStack.
    func showConversations() {
        var p = NavigationPath()
        p.append(ConversationsRoute())
        path = p
    }

    // MARK: - Scene restoration

    /// Scene-restoration hook invoked once when a signed-in scene appears.
    ///
    /// The app always launches into the Library home. We intentionally do NOT
    /// reopen the last-open book: the persisted scene cells are ignored and the
    /// navigation path is left at the Library root. A reader route already
    /// pushed onto `path` by a cold-launch deep link (`handle(url:)`) is
    /// preserved, because this method never mutates `path`.
    func applyRestored(
        tabRaw _: String,
        openBookIdRaw _: String,
        bookStore _: (any BookStore)?
    ) async {
        // No-op: start at the Library on every launch.
    }

    /// Encodes the live navigation state into `@SceneStorage`-compatible
    /// primitive strings. Mirrors `RootView.persistSceneState()`.
    ///
    /// Returns `(tabRaw:openBookIdRaw:)` — assign directly to the caller's
    /// `@SceneStorage` cells.
    func persistCells() -> (tabRaw: String, openBookIdRaw: String) {
        // Tab cell is always `.library` in the current single-home layout;
        // retained for schema continuity with existing installs.
        let state = RishiSceneState(selectedTab: .library, openBookId: nil)
        let tabRaw = state.encodeForStorage()
        let openBookIdRaw = NavigationPath.encodeForStorage(path)
        return (tabRaw: tabRaw, openBookIdRaw: openBookIdRaw)
    }
}
