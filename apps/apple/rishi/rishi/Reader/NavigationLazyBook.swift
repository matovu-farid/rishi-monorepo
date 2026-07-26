




import SwiftUI







struct NavigationLazyBook<Content: View>: View {
    let bookId: BookID
    let bookStore: any BookStore
    let content: (Book) -> Content

    @State private var book: Book?

    
    
    
    
    
    
    init(bookId: BookID,
         hint: Book? = nil,
         bookStore: any BookStore,
         @ViewBuilder content: @escaping (Book) -> Content) {
        self.bookId = bookId
        self.bookStore = bookStore
        self.content = content
        self._book = State(initialValue: hint)
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
                book = try? await bookStore.book(bookId)
            }
        }
    }
}
