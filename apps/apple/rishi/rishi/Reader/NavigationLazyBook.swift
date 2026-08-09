




import SwiftUI







struct NavigationLazyBook<Content: View>: View {
    let bookId: BookID
    let ownerId: UserID?
    let bookStore: any BookStore
    let content: (Book) -> Content

    @State private var book: Book?

    
    
    
    
    
    
    init(bookId: BookID,
         hint: Book? = nil,
         ownerId: UserID? = nil,
         bookStore: any BookStore,
         @ViewBuilder content: @escaping (Book) -> Content) {
        self.bookId = bookId
        self.ownerId = ownerId
        self.bookStore = bookStore
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
    }
}
