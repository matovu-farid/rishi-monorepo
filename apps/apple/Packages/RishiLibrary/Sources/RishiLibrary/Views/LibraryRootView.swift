import SwiftUI
import RishiCore
import RishiUIKit
import Foundation
import os.signpost

/// Phase 12 Plan 12-01 — notification names mirrored from the rishi app's
/// `RishiCommand` enum so the library package can subscribe without
/// depending on the host target. Raw string values MUST match the app's
/// declaration in `rishi/rishi/Mac/RishiKeyboardCommands.swift`.
private enum LibraryMacCommandNotification {
    static let importBook  = Notification.Name("RishiCommand.importBook")
    static let focusSearch = Notification.Name("RishiCommand.focusSearch")
}

/// Phase 19 Plan 19-08 (F-P2-04) — file-static signposter so Instruments
/// Time Profiler can attribute the library first-paint cost (refresh +
/// parallel cover-URL fan-out). `OSSignposter` is `Sendable`, so the
/// nonisolated declaration is safe to share across MainActor view bodies
/// and the `Task` that runs the `.task` body.
private let librarySignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "library"
)

/// Top-level library shell mounted by the rishi app. Wraps `LibraryView` in a
/// `NavigationStack` and wires in:
///   - `.searchable(...)` via `librarySearchable(text:filteredIsEmpty:)`
///   - drop-destination via `libraryDropDestination(coordinator:onImported:)`
///   - toolbar "Import" button presenting `DocumentPickerView`
///
/// Reads `LibraryViewModel` from the SwiftUI environment via
/// `@Environment(LibraryViewModel.self)` — paired with `.environment(deps.libraryViewModel)`
/// in `rishiApp` so every descendant sees the same `@Observable` instance.
@MainActor
public struct LibraryRootView: View {

    @Environment(LibraryViewModel.self) private var viewModel
    public let importCoordinator: ImportCoordinator
    public let onOpenBook: (Book) -> Void

    /// Phase 7 (07-05): optional gear-icon callback so the host app can
    /// surface a Settings sheet without RishiLibrary knowing what's in it.
    /// `nil` (the default) hides the button entirely so older callers and
    /// tests continue to render the same toolbar.
    public let onShowSettings: (() -> Void)?

    /// Phase 18 Plan 18-01 — when non-nil, the host app owns the outer
    /// `NavigationStack(path:)` and this view renders without wrapping its
    /// content in another stack. Required for the reader push migration
    /// (F-P0-01) — nested stacks crash iPad split-view.
    ///
    /// Legacy init (path == nil) keeps the previous behavior so existing
    /// previews and any non-app callers keep compiling.
    private let externalPath: Binding<NavigationPath>?

    @State private var showDocumentPicker = false
    @State private var coverURLs: [BookID: URL] = [:]

    /// Legacy initializer — wraps content in a self-owned NavigationStack.
    /// Kept for previews + future callers that want the simple shape.
    public init(importCoordinator: ImportCoordinator,
                onOpenBook: @escaping (Book) -> Void,
                onShowSettings: (() -> Void)? = nil) {
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.externalPath = nil
    }

    /// Phase 18 Plan 18-01 — host-owned NavigationStack initializer. The
    /// rishi app target uses this so the reader can be pushed onto the
    /// SAME stack and the system back chevron / edge-swipe always work.
    public init(path: Binding<NavigationPath>,
                importCoordinator: ImportCoordinator,
                onOpenBook: @escaping (Book) -> Void,
                onShowSettings: (() -> Void)? = nil) {
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.externalPath = path
    }

    public var body: some View {
        @Bindable var vm = viewModel
        return Group {
            if externalPath != nil {
                // Host owns the NavigationStack — render bare content so the
                // outer stack provides the chrome (chevron, edge-swipe, etc).
                libraryContent(vm: vm)
            } else {
                NavigationStack {
                    libraryContent(vm: vm)
                }
            }
        }
        .librarySearchable(text: $vm.searchText,
                           filteredIsEmpty: !vm.searchText.isEmpty && vm.filteredBooks.isEmpty)
        .libraryDropDestination(coordinator: importCoordinator) { _ in
            Task {
                await vm.refresh()
                await reloadCovers()
            }
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                showDocumentPicker = false
                guard !urls.isEmpty else { return }
                Task {
                    _ = await importCoordinator.importBooks(urls)
                    await vm.refresh()
                    await reloadCovers()
                }
            }
        }
        #endif
        .task {
            // Phase 19 Plan 19-08 (F-P2-04) — wrap the first-paint hot path
            // so Instruments captures the combined cost of viewModel.refresh
            // (GRDB book fetch) and reloadCovers (parallel cover-URL fan-out).
            // Pure additive; behavior is unchanged.
            let state = librarySignposter.beginInterval("library.first-paint")
            defer { librarySignposter.endInterval("library.first-paint", state) }
            await vm.refresh()
            await reloadCovers()
        }
        // Phase 12 Plan 12-01 — Mac menu / ⌘O routes through here so the
        // existing iOS toolbar button and the Catalyst menu share one path.
        .onReceive(NotificationCenter.default.publisher(for: LibraryMacCommandNotification.importBook)) { _ in
            #if canImport(UIKit)
            showDocumentPicker = true
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryMacCommandNotification.focusSearch)) { _ in
            // SwiftUI doesn't expose direct focus control on `.searchable`,
            // so we surface the intent by clearing the search text. Users
            // see the cursor in the field and start typing. Plan 12-04 may
            // upgrade this to `@FocusState` once the a11y audit lands.
            vm.searchText = ""
        }
    }

    @ViewBuilder
    private func libraryContent(vm: LibraryViewModel) -> some View {
        LibraryView(
            books: vm.searchText.isEmpty ? vm.books : vm.filteredBooks,
            readingNow: vm.readingNow,
            positionLookup: { vm.position(for: $0) },
            coverURL: { coverURLs[$0.id] },
            onOpen: onOpenBook,
            onDelete: { book in Task { await vm.delete(book) } }
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDocumentPicker = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            if let onShowSettings {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        onShowSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
    }

    private func reloadCovers() async {
        let books = viewModel.books
        let pairs = await Self.computeCoverURLs(books: books) { [viewModel] book in
            await viewModel.coverURL(for: book)
        }
        coverURLs = pairs
    }

    /// Phase 19 Plan 19-02 (F-P0-02) — parallelisable kernel of `reloadCovers`.
    ///
    /// Replaces the prior serial `for book in books { await ... }` loop with a
    /// `withTaskGroup` parallel fan-out per Swift book / "Calling Asynchronous
    /// Functions in Parallel". For a 50-book library this collapses 50 serial
    /// MainActor hops into one `await` that resumes once all child tasks have
    /// completed concurrently.
    ///
    /// `nonisolated` because the body does no UI state mutation — every value
    /// flowing through is `Sendable` and the result dictionary is returned to
    /// the caller, who owns the @State write back on MainActor.
    nonisolated static func computeCoverURLs(
        books: [Book],
        coverURLFor: @Sendable @escaping (Book) async -> URL?
    ) async -> [BookID: URL] {
        await withTaskGroup(of: (BookID, URL?).self) { group in
            for book in books {
                group.addTask {
                    let url = await coverURLFor(book)
                    return (book.id, url)
                }
            }
            var out: [BookID: URL] = [:]
            for await (id, url) in group {
                if let url { out[id] = url }
            }
            return out
        }
    }
}

private actor LibraryRootPreviewBookStore: BookStore {
    private var byId: [BookID: Book] = [:]

    init(seed: [Book]) {
        for b in seed { byId[b.id] = b }
    }

    func books(for userId: UserID) async throws -> [Book] {
        byId.values.filter { $0.userId == userId }.sorted { $0.title < $1.title }
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

    func position(for bookId: BookID) async throws -> Position? { byBook[bookId] }

    func upsert(_ position: Position) async throws { byBook[position.bookId] = position }

    func delete(_ id: PositionID) async throws {
        if let key = byBook.first(where: { $0.value.id == id })?.key {
            byBook[key] = nil
        }
    }
}

@MainActor
private enum LibraryRootPreviewFixtures {
    static let userId: UserID = UUID()

    static func book(_ title: String, author: String? = "Preview Author") -> Book {
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
        book("Designing Data-Intensive Applications", author: "Martin Kleppmann"),
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
        let positionStore = LibraryRootPreviewPositionStore(seed: positions(for: books))
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RishiLibraryPreview-\(UUID().uuidString)", isDirectory: true)
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: bookStore,
            coverExtractors: [:]
        )
        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId }
        )
        return vm
    }

    static func makeImportCoordinator() -> ImportCoordinator {
        let bookStore = LibraryRootPreviewBookStore(seed: [])
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RishiLibraryPreviewImport-\(UUID().uuidString)", isDirectory: true)
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

#Preview("Root - populated") {
    LibraryRootView(
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in }
    )
    .environment(LibraryRootPreviewFixtures.makeViewModel(books: LibraryRootPreviewFixtures.populated))
}

#Preview("Root - empty") {
    LibraryRootView(
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in }
    )
    .environment(LibraryRootPreviewFixtures.makeViewModel(books: []))
}

#Preview("Root - with settings button") {
    LibraryRootView(
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in },
        onShowSettings: { }
    )
    .environment(LibraryRootPreviewFixtures.makeViewModel(books: LibraryRootPreviewFixtures.populated))
}

#Preview("Root - dark mode") {
    LibraryRootView(
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in }
    )
    .environment(LibraryRootPreviewFixtures.makeViewModel(books: LibraryRootPreviewFixtures.populated))
    .preferredColorScheme(.dark)
}
