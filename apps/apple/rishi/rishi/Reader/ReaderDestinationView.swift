import RishiCore
import RishiReader
import SwiftUI

struct ReaderDestinationView: View {
    let route: ReaderRoute
    let hint: Book?
    let onRequestPaywall: (String) -> Void

    @Environment(AppRouter.self) private var router
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
                bookStore: services.bookStore
            ) { book in
                ReaderDestination(
                    vm: ReaderViewModel.make(
                        book: book,
                        userId: userId,
                        services: services
                    ),
                    services: services,
                    userId: userId,
                    onRequestPaywall: onRequestPaywall
                )
            }
        case .unsupportedFormat(let bookId):
            NavigationLazyBook(
                bookId: bookId,
                hint: hint,
                bookStore: services.bookStore
            ) { book in
                EpubPlaceholderView(book: book) {
                    if !router.path.isEmpty { router.path.removeLast() }
                }
            }
        }
    }
}
