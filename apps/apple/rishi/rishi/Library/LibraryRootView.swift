import Foundation
import TipKit


import SwiftUI
import os.signpost



private enum LibraryMacCommandNotification {
    static let importBook = Notification.Name("RishiCommand.importBook")
    static let focusSearch = Notification.Name("RishiCommand.focusSearch")
}

private let librarySignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "library"
)



@MainActor
public struct LibraryRootView: View {
    @Environment(LibraryViewModel.self) private var vm: LibraryViewModel


    public let importCoordinator: ImportCoordinator
    public let onOpenBook: (Book) -> Void

    public let onShowSettings: (() -> Void)
    
    private var importTip = ImportBooksTip()

    public let onImported:
        (@MainActor ([ImportCoordinator.ImportOutcome]) -> Void)?

    ///

    private let externalPath: Binding<NavigationPath>?

    @State private var internalDocumentPickerPresented = false
    private let externalDocumentPickerPresented: Binding<Bool>?

    private var documentPickerPresented: Binding<Bool> {
        externalDocumentPickerPresented ?? $internalDocumentPickerPresented
    }

    public init(
      
        importCoordinator: ImportCoordinator,
        onOpenBook: @escaping (Book) -> Void,
        onShowSettings: @escaping (() -> Void),
        onImported: (@MainActor ([ImportCoordinator.ImportOutcome]) -> Void)? =
            nil,
        documentPickerPresented: Binding<Bool>? = nil
    ) {
 
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.onImported = onImported
        self.externalPath = nil
        self.externalDocumentPickerPresented = documentPickerPresented
    }

    public init(
     
        path: Binding<NavigationPath>,
        importCoordinator: ImportCoordinator,
        onOpenBook: @escaping (Book) -> Void,
        onShowSettings: @escaping (() -> Void),
        onImported: (@MainActor ([ImportCoordinator.ImportOutcome]) -> Void)? =
            nil,
        documentPickerPresented: Binding<Bool>? = nil
    ) {
       
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.onImported = onImported
        self.externalPath = path
        self.externalDocumentPickerPresented = documentPickerPresented
    }

    public var body: some View {
        @Bindable var vm = vm
        return libraryContent(vm: vm)
       
        .libraryDropDestination(coordinator: importCoordinator) { outcomes in

            Task {
                await vm.refresh()
                onImported?(outcomes)
            }
        }

#if canImport(UIKit)
        .sheet(isPresented: documentPickerPresented) {
            DocumentPickerView { urls in
                Log.event(
                    "library.import.picker.completed",
                    data: [
                        "count": String(urls.count),
                        "files": urls.map(\.lastPathComponent).joined(separator: ",")
                    ]
                )
                documentPickerPresented.wrappedValue = false
                Task {
                    let outcomes = await vm.importPicked(urls)
                    Log.event(
                        "library.import.picker.outcomes",
                        data: [
                            "count": String(outcomes.count),
                            "successes": String(outcomes.filter { $0.book != nil }.count),
                            "failures": String(outcomes.filter { $0.error != nil }.count)
                        ]
                    )
                    onImported?(outcomes)
                }
            }
        }
#endif
        .alert(item: $vm.importError) { failure in
            Alert(
                title: Text("Import Failed"),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {

            let state = librarySignposter.beginInterval("library.first-paint")
            defer {
                librarySignposter.endInterval("library.first-paint", state)
            }
            await vm.refresh()
        }

        .onReceive(
            NotificationCenter.default.publisher(
                for: LibraryMacCommandNotification.importBook
            )
        ) { _ in
            #if canImport(UIKit)
                documentPickerPresented.wrappedValue = true
            #endif
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: LibraryMacCommandNotification.focusSearch
            )
        ) { _ in

            vm.searchText = ""
        }
    }

    
    
    @ViewBuilder
    private func libraryContent(vm: LibraryViewModel) -> some View {
        @Bindable var vm = vm
        LibraryView(
            books: vm.searchText.isEmpty ? vm.books : vm.filteredBooks,
            positionLookup: { bookID in vm.position(for: bookID) },
            coverURL: { book in vm.coverURLs[book.id] },
            onOpen: onOpenBook,

            onDelete: { book in Task { await vm.delete(book) } }
        )

        .librarySearchable(
            text: $vm.searchText,
            filteredIsEmpty: !vm.searchText.isEmpty && vm.filteredBooks.isEmpty
        )
        .toolbar {

            ToolbarItem(placement: .primaryAction) {

                    Button {
                        documentPickerPresented.wrappedValue = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .popoverTip(importTip)
                    
        

            }
            
            

            #if os(iOS) && !targetEnvironment(macCatalyst)

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onShowSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            #endif

        }
    }
}

private actor LibraryRootPreviewBookStore: BookStore {
    private var byId: [BookID: Book] = [:]

    init(seed: [Book]) {
        for b in seed { byId[b.id] = b }
    }

    func books(for userId: UserID) async throws -> [Book] {
        byId.values.filter { book in book.userId == userId }.sorted {
            left,
            right in left.title < right.title
        }
    }

    func book(_ id: BookID) async throws -> Book? { byId[id] }

    func upsert(_ book: Book) async throws { byId[book.id] = book }

    func delete(_ id: BookID) async throws { byId[id] = nil }
}

private actor LibraryRootPreviewPositionStore: PositionStore {
    private var byBook: [BookID: Position] = [:]

    init(seed: [Position]) {
        for p in seed { byBook[p.bookId] = p }
    }

    func position(for bookId: BookID) async throws -> Position? {
        byBook[bookId]
    }

    func upsert(_ position: Position) async throws {
        byBook[position.bookId] = position
    }

    func delete(_ id: PositionID) async throws {
        if let key = byBook.first(where: { entry in entry.value.id == id })?.key
        {
            byBook[key] = nil
        }
    }
}

@MainActor
private enum LibraryRootPreviewFixtures {
    static let userId: UserID = UUID()

    static func book(_ title: String, author: String? = "Preview Author")
        -> Book
    {
        Book(
            id: UUID(),
            userId: userId,
            title: title,
            author: author,
            formatType: .epub,
            fileURL: "Books/\(UUID().uuidString)/\(title).epub"
        )
    }

    static let populated: [Book] = [
        book("Project Hail Mary", author: "Andy Weir"),
        book("Sapiens", author: "Yuval Noah Harari"),
        book("The Pragmatic Programmer", author: "Hunt and Thomas"),
        book("Norwegian Wood", author: "Haruki Murakami"),
        book(
            "Designing Data-Intensive Applications",
            author: "Martin Kleppmann"
        ),
        book("Dune", author: "Frank Herbert"),
    ]

    static func positions(for books: [Book]) -> [Position] {
        books.prefix(2).map { b in
            Position(
                id: UUID(),
                bookId: b.id,
                locator: "{\"page\":1}",
                percentComplete: 0.4,
                updatedAt: Date()
            )
        }
    }

    static func makeViewModel(books: [Book]) -> LibraryViewModel {
        let bookStore = LibraryRootPreviewBookStore(seed: books)
        let positionStore = LibraryRootPreviewPositionStore(
            seed: positions(for: books)
        )
        let tmp = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "RishiLibraryPreview-\(UUID().uuidString)",
            isDirectory: true
        )
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: bookStore,
            coverExtractors: [:]
        )
        let capturedUserId = userId
        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(
                storage: storage,
                currentUserId: { capturedUserId }
            )
        )
        return vm
    }

    static func makeImportCoordinator() -> ImportCoordinator {
        let bookStore = LibraryRootPreviewBookStore(seed: [])
        let tmp = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "RishiLibraryPreviewImport-\(UUID().uuidString)",
            isDirectory: true
        )
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: bookStore,
            coverExtractors: [:]
        )
        let capturedUserId = userId
        return ImportCoordinator(
            storage: storage,
            currentUserId: { capturedUserId }
        )
    }
}

struct ImportBooksTip: Tip {
    var title: Text {
        Text("Bring your library with you")
    }
    
    var message: Text? {
        Text("Import your EPUB and PDF books to read, listen, and chat with them in one place.")
    }
    
    var image: Image? {
        Image(systemName: "square.and.arrow.down")
    }
}
