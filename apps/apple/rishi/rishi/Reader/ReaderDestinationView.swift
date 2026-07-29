

import SwiftUI

struct ReaderDestinationView: View {
    let route: ReaderRoute
    let hint: Book?
    let onRequestPaywall: (String) -> Void
    var pdfViewMode: Binding<PDFViewModeSetting>? = nil

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var servicesEnv
    @Environment(CurrentUserBox.self) private var currentUser
    var user:User? {
        if case .signedIn(user: let user) = currentUser.state {
            return user
        }
        return nil
    }

    var body: some View {

        let services = servicesEnv!
        let userId = user!.id
        switch route {
        case .epub(let bookId),.pdf(let bookId):
            NavigationLazyBook(
                bookId: bookId,
                hint: hint,
                bookStore: services.library.bookStore
            ) { book in
                ReaderDestination(
                    vm: ReaderViewModel.make(
                        book: book,
                        userId: userId,
                        services: services
                    ),
                    services: services,
                    userId: userId,
                    onRequestPaywall: onRequestPaywall,
                    pdfViewMode: pdfViewMode
                )
            }
        case .unsupportedFormat(let bookId):
            NavigationLazyBook(
                bookId: bookId,
                hint: hint,
                bookStore: services.library.bookStore
            ) { book in
                EpubPlaceholderView(book: book) {
                    #if targetEnvironment(macCatalyst)
                        dismiss()
                    #else
                        if !router.path.isEmpty { router.path.removeLast() }
                    #endif
                }
            }
        }
    }
}
