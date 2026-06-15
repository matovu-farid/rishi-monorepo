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
    let services: BootstrappedServices
    let userId: UserID
    let hint: Book?
    let onRequestPaywall: (String) -> Void

    @Environment(AppRouter.self) private var router

    var body: some View {
        switch route {
        case .pdf(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                PDFReaderDestination(
                    book: book,
                    services: services,
                    userId: userId,
                    onRequestPaywall: onRequestPaywall
                )
            }
        case .epub(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                EPUBReaderDestination(
                    book: book,
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
