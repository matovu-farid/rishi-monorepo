

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
    @State private var startReaderTour = false
    @State private var didResolveReaderTourRequest = false
    var user:User? {
        if case .signedIn(user: let user) = currentUser.state {
            return user
        }
        return nil
    }

    var body: some View {

        let services = servicesEnv!
        let userId = user!.id
        Group {
            switch route {
            case .epub(let bookId),.pdf(let bookId):
                NavigationLazyBook(
                    bookId: bookId,
                    hint: hint,
                    ownerId: userId,
                    bookStore: services.library.bookStore
                ) { book in
                    ReaderDestination(
                        vm: ReaderViewModel.make(
                            book: book,
                            userId: userId,
                            positionStore: services.library.positionStore
                        ),
                        dependencies: ReaderDestinationDependencies.make(services: services),
                        userId: userId,
                        onRequestPaywall: onRequestPaywall,
                        startReaderTour: startReaderTour,
                        pdfViewMode: pdfViewMode
                    )
                    // The transient tour request is consumed when this
                    // destination appears. Recreate the destination subtree
                    // after that flag resolves so its @State coordinator,
                    // voice callback, and reader chrome are initialized with
                    // the guided configuration on iOS and Catalyst.
                    .id(startReaderTour)
                }
            case .unsupportedFormat(let bookId):
                NavigationLazyBook(
                    bookId: bookId,
                    hint: hint,
                    ownerId: userId,
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
        .onAppear {
            guard !didResolveReaderTourRequest, let user else { return }
            didResolveReaderTourRequest = true
            startReaderTour = router.takeReaderTour(
                for: route.bookId,
                userID: user.id
            )
        }
    }
}

private actor ReaderDestinationPreviewPositionStore: PositionStore {
    func position(for bookId: BookID) async throws -> Position? { nil }
    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

@MainActor
private func makeReaderDestinationPreviewViewModel() -> ReaderViewModel {
    let url = AppResourceBundle.bundle.url(forResource: "alice", withExtension: "epub")
        ?? URL(fileURLWithPath: "/dev/null")
    let book = Book(
        userId: UUID(),
        title: "Alice's Adventures in Wonderland",
        author: "Lewis Carroll",
        formatType: .epub,
        fileURL: url.path
    )
    return ReaderViewModel(
        book: book,
        userId: book.userId,
        documentURL: url,
        positionStore: ReaderDestinationPreviewPositionStore()
    )
}

#Preview("Reader destination — EPUB") {
    ReaderScreen(viewModel: makeReaderDestinationPreviewViewModel())
}
