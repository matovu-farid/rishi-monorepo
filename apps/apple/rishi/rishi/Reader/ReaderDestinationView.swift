//
//  ReaderDestinationView.swift
//  rishi
//
//  Phase 29 refactor — promotes destinationView(for:services:userId:) from
//  SignedInView into its own View struct. Switches on ReaderRoute and wraps
//  each case in NavigationLazyBook so the BookID->Book resolution stays lazy.
//
//  ReaderRoute.bookId already exists on the public enum (RishiReader package),
//  so no local extension is needed.
//

import SwiftUI
import RishiCore
import RishiReader

struct ReaderDestinationView: View {
    let route: ReaderRoute
    let hint: Book?
    let onRequestPaywall: (String) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(\.services) private var servicesEnv
    @Environment(\.currentUser) private var currentUser

    var body: some View {
        // Force-unwrap under the RootView.realBody non-nil guard contract:
        // ReaderDestinationView is only mounted in LibraryTabView's
        // .navigationDestination, which lives under the signed-in subtree where
        // both env values are guaranteed present (RESEARCH Risk #1).
        let services = servicesEnv!
        let userId = currentUser!.id
        switch route {
        case .pdf(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                PDFReaderDestination(
                    vm: PDFReaderViewModel.make(book: book, userId: userId, services: services),
                    services: services,
                    userId: userId,
                    onRequestPaywall: onRequestPaywall
                )
            }
        case .epub(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                EPUBReaderDestination(
                    vm: EPUBReaderViewModel.make(book: book, userId: userId, services: services),
                    services: services,
                    userId: userId,
                    onRequestPaywall: onRequestPaywall
                )
            }
        case .unsupportedFormat(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                EpubPlaceholderView(book: book) {
                    if !router.path.isEmpty { router.path.removeLast() }
                }
            }
        }
    }
}
