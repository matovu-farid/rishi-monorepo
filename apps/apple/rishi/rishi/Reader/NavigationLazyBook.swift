




import SwiftUI







struct NavigationLazyBook<Content: View>: View {
    let bookId: BookID
    let ownerId: UserID?
    let bookStore: any BookStore
    /// Changes when an already-rendered reader is promoted into a new shared
    /// session, making the one-shot readiness callback eligible again.
    let readinessKey: String?
    let onBookLoaded: (Book) -> Void
    let content: (Book) -> Content

    @State private var book: Book?
    @State private var didNotifyBookLoaded = false

    
    
    
    
    
    
    init(bookId: BookID,
         hint: Book? = nil,
         ownerId: UserID? = nil,
         bookStore: any BookStore,
         readinessKey: String? = nil,
         onBookLoaded: @escaping (Book) -> Void = { _ in },
         @ViewBuilder content: @escaping (Book) -> Content) {
        self.bookId = bookId
        self.ownerId = ownerId
        self.bookStore = bookStore
        self.readinessKey = readinessKey
        self.onBookLoaded = onBookLoaded
        self.content = content
        self._book = State(
            initialValue: hint.flatMap { candidate in
                guard ownerId == nil || candidate.userId == ownerId else { return nil }
                return candidate
            }
        )
    }

    var body: some View {
        Group {
            if let book {
                content(book)
                    .onAppear { notifyBookLoaded(book) }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: bookId) {
            if book == nil {
                let loaded = try? await bookStore.book(bookId)
                guard let loaded,
                      ownerId == nil || loaded.userId == ownerId
                else { return }
                book = loaded
            }
        }
        .onChange(of: readinessKey) { _, _ in
            didNotifyBookLoaded = false
            if let book { notifyBookLoaded(book) }
        }
    }

    private func notifyBookLoaded(_ loadedBook: Book) {
        guard !didNotifyBookLoaded else { return }
        didNotifyBookLoaded = true
        onBookLoaded(loadedBook)
    }
}
