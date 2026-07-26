import Foundation


import SwiftUI

#if targetEnvironment(macCatalyst)

/// Stable identity for a Catalyst reader window. The account is part of the
/// identity so a restored window can never be reused for another account.
struct ReaderWindowID: Hashable, Codable, Sendable {
    let userID: UserID
    let bookID: BookID

    init(userID: UserID, bookID: BookID) {
        self.userID = userID
        self.bookID = bookID
    }
}

struct ReaderWindowInput: Hashable, Codable, Sendable, Identifiable {
    let id: ReaderWindowID
    let route: ReaderRoute

    init(userID: UserID, route: ReaderRoute) {
        self.id = ReaderWindowID(userID: userID, bookID: route.bookId)
        self.route = route
    }
}

@MainActor
@Observable
final class PDFReaderPresentationState {
    var requestedMode: PDFViewModeSetting
    private(set) var effectiveMode: PDFViewModeSetting
    var isTransitioning = false

    init(mode: PDFViewModeSetting = .continuous) {
        requestedMode = mode
        effectiveMode = mode
    }

    func beginTransition(to mode: PDFViewModeSetting) {
        requestedMode = mode
        isTransitioning = true
    }

    func didApply(mode: PDFViewModeSetting) {
        effectiveMode = mode
        requestedMode = mode
        isTransitioning = false
    }
}

struct ReaderWindowRestorationState: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let userID: UserID
    let windows: [ReaderWindowInput]

    init(userID: UserID, windows: [ReaderWindowInput], version: Int = currentVersion) {
        self.version = version
        self.userID = userID
        self.windows = windows
    }
}

@MainActor
@Observable
final class ReaderWindowCoordinator {
    private(set) var openWindows: [ReaderWindowID: ReaderWindowInput] = [:]

    private var openWindowAction: OpenWindowAction?
    private var closeWindowAction: DismissWindowAction?

    func configure(
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        openWindowAction = openWindow
        closeWindowAction = dismissWindow
    }

    func open(book: Book, user: User) {
        open(route: ReaderRoute.route(for: book), userID: user.id)
    }

    func open(route: ReaderRoute, userID: UserID) {
        let input = ReaderWindowInput(userID: userID, route: route)
        let inserted = openWindows.updateValue(input, forKey: input.id) == nil
        openWindowAction?(id: "reader", value: input)
        if !inserted {
            // Opening a value that already exists asks SwiftUI to focus the
            // existing scene instead of creating another reader.
            return
        }
    }

    func focus(bookID: BookID, userID: UserID) {
        guard let input = openWindows[ReaderWindowID(userID: userID, bookID: bookID)] else {
            return
        }
        openWindowAction?(id: "reader", value: input)
    }

    func close(bookID: BookID, userID: UserID) {
        let id = ReaderWindowID(userID: userID, bookID: bookID)
        guard let input = openWindows.removeValue(forKey: id) else { return }
        closeWindowAction?(value: input)
    }

    func register(_ input: ReaderWindowInput) {
        openWindows[input.id] = input
    }

    func unregister(_ input: ReaderWindowInput) {
        openWindows.removeValue(forKey: input.id)
    }

    func invalidate(userID: UserID) {
        let ids = openWindows.keys.filter { $0.userID == userID }
        for id in ids {
            close(bookID: id.bookID, userID: id.userID)
        }
    }

    func restorationState(userID: UserID) -> ReaderWindowRestorationState {
        ReaderWindowRestorationState(
            userID: userID,
            windows: openWindows.values
                .filter { $0.id.userID == userID }
                .sorted { $0.id.bookID.uuidString < $1.id.bookID.uuidString }
        )
    }

    func restore(
        state: ReaderWindowRestorationState,
        user: User,
        bookStore: any BookStore
    ) async {
        guard state.version == ReaderWindowRestorationState.currentVersion,
              state.userID == user.id else { return }

        for input in state.windows where input.id.userID == user.id {
            guard let book = try? await bookStore.book(input.id.bookID),
                  book.userId == user.id else {
                continue
            }
            open(route: input.route, userID: user.id)
        }
    }
}

#endif
