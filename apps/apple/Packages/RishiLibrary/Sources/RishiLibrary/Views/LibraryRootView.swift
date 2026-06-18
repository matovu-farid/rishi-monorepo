import SwiftUI
import RishiCore
import RishiUIKit
import Foundation
import UniformTypeIdentifiers
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
/// `@Environment(LibraryViewModel.self)` — paired with `.environment(libraryVM)`
/// in `SignedInView` so every descendant sees the same `@Observable` instance.
///
/// Phase 21 Plan 21-01 — `LibraryViewModel.refresh()` now owns the cover-URL
/// fan-out via the nonisolated `BookFileStorage.cachedCoverURLIfFresh` fast
/// path, so this view no longer maintains a `@State` cover-URL dictionary
/// nor runs a post-render `reloadCovers()` wave. The grid binds the
/// `coverURL:` projection directly to `vm.coverURLs`, so cache-warm books
/// render real covers on the first paint after `await vm.refresh()`
/// returns.
@MainActor
public struct LibraryRootView: View {

    private let viewModel: LibraryViewModel
    public let importCoordinator: ImportCoordinator
    public let onOpenBook: (Book) -> Void

    /// Phase 7 (07-05): optional gear-icon callback so the host app can
    /// surface a Settings sheet without RishiLibrary knowing what's in it.
    /// `nil` (the default) hides the button entirely so older callers and
    /// tests continue to render the same toolbar.
    public let onShowSettings: (() -> Void)?

    /// Optional Chats entry point. When non-nil, the toolbar surfaces a
    /// conversations button so a host that has removed the bottom tab bar
    /// (iPhone compact) can still reach the Chats surface. `nil` (the
    /// default) hides it — used by the iPad/Mac sidebar layout, where Chats
    /// is a sidebar entry, and by previews/tests.
    public let onShowChats: (() -> Void)?

    /// Phase 21 follow-up — fires once per import batch with the resulting
    /// outcomes. Host app uses this to auto-open the reader when a SINGLE
    /// book was imported successfully. Multi-book batches keep the user on
    /// the library (we don't try to fan out into N readers). `nil` (the
    /// default) preserves legacy behaviour where the host doesn't react.
    public let onImported: (@MainActor ([ImportCoordinator.ImportOutcome]) -> Void)?

    /// Phase 18 Plan 18-01 — when non-nil, the host app owns the outer
    /// `NavigationStack(path:)` and this view renders without wrapping its
    /// content in another stack. Required for the reader push migration
    /// (F-P0-01) — nested stacks crash iPad split-view.
    ///
    /// Legacy init (path == nil) keeps the previous behavior so existing
    /// previews and any non-app callers keep compiling.
    private let externalPath: Binding<NavigationPath>?

    @State private var showDocumentPicker = false

    /// Legacy initializer — wraps content in a self-owned NavigationStack.
    /// Kept for previews + future callers that want the simple shape.
    public init(viewModel: LibraryViewModel,
                importCoordinator: ImportCoordinator,
                onOpenBook: @escaping (Book) -> Void,
                onShowSettings: (() -> Void)? = nil,
                onShowChats: (() -> Void)? = nil,
                onImported: (@MainActor ([ImportCoordinator.ImportOutcome]) -> Void)? = nil) {
        self.viewModel = viewModel
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.onShowChats = onShowChats
        self.onImported = onImported
        self.externalPath = nil
    }

    /// Phase 18 Plan 18-01 — host-owned NavigationStack initializer. The
    /// rishi app target uses this so the reader can be pushed onto the
    /// SAME stack and the system back chevron / edge-swipe always work.
    public init(viewModel: LibraryViewModel,
                path: Binding<NavigationPath>,
                importCoordinator: ImportCoordinator,
                onOpenBook: @escaping (Book) -> Void,
                onShowSettings: (() -> Void)? = nil,
                onShowChats: (() -> Void)? = nil,
                onImported: (@MainActor ([ImportCoordinator.ImportOutcome]) -> Void)? = nil) {
        self.viewModel = viewModel
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.onShowChats = onShowChats
        self.onImported = onImported
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
        .libraryDropDestination(coordinator: importCoordinator) { outcomes in
            // Phase 21 Plan 21-01 — `vm.refresh()` now owns the cover-URL
            // fan-out internally (nonisolated cache fast path inside a
            // withTaskGroup), so the post-refresh `reloadCovers()` wave is
            // gone. The host's auto-open hook still fires AFTER refresh so
            // bookHints + path push see the new book in `vm.books`.
            Task {
                await vm.refresh()
                onImported?(outcomes)
            }
        }
        // SwiftUI-native importer — on Mac Catalyst SwiftUI manages the
        // out-of-process NSOpenPanel and keeps its own completion alive, so the
        // picked URLs are always delivered. The prior `.sheet`+DocumentPickerView
        // path lost its UIDocumentPickerDelegate when Catalyst floated the panel
        // as a separate window, so imports failed silently on Mac.
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: [.epub, .pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                // importPicked routes through ImportCoordinator (security-scoped
                // resource dance + sync dirty-marking), refreshes, then surfaces
                // an error if nothing imported.
                Task {
                    let outcomes = await vm.importPicked(urls)
                    onImported?(outcomes)
                }
            case .failure(let error):
                vm.importError = .init(message: "Couldn't open the selected file. \(error.localizedDescription)")
            }
        }
        .alert(item: $vm.importError) { failure in
            Alert(title: Text("Import Failed"),
                  message: Text(failure.message),
                  dismissButton: .default(Text("OK")))
        }
        .task {
            // Phase 19 Plan 19-08 (F-P2-04) — wrap the first-paint hot path
            // so Instruments captures the cost of viewModel.refresh, which
            // (post Phase 21 Plan 21-01) ALSO owns the parallel cover-URL
            // fan-out via the nonisolated cache fast path. The interval
            // therefore still captures the full first-paint cost. The
            // previously-paired id-keyed catch-up `.task` (which re-ran a
            // separate cover-URL wave when the book set changed) is gone
            // too: any later refresh re-publishes coverURLs
            // in the same MainActor turn as `vm.books`, so SwiftUI's diff
            // sees real URLs in the same render pass.
            let state = librarySignposter.beginInterval("library.first-paint")
            defer { librarySignposter.endInterval("library.first-paint", state) }
            await vm.refresh()
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
            positionLookup: { bookID in vm.position(for: bookID) },
            coverURL: { book in vm.coverURLs[book.id] },
            onOpen: onOpenBook,
            // KEEP: vm.delete is @MainActor (LibraryViewModel @MainActor); the
            // BookFileStorage delete inside it hops to its own actor executor.
            // Outer Task chains the await; UI-state mutation only.
            onDelete: { book in Task { await vm.delete(book) } }
        )
        .toolbar {
            if let onShowChats {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onShowChats()
                    } label: {
                        Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("library.toolbar.chats")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDocumentPicker = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                // No inline .keyboardShortcut("o"): the universal "Import Book…"
                // menu command owns Cmd+O. A second claimant here collides with
                // it (and previously with AppKit's system Open) on Mac.
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
}

private actor LibraryRootPreviewBookStore: BookStore {
    private var byId: [BookID: Book] = [:]

    init(seed: [Book]) {
        for b in seed { byId[b.id] = b }
    }

    func books(for userId: UserID) async throws -> [Book] {
        byId.values.filter { book in book.userId == userId }.sorted { left, right in left.title < right.title }
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
        if let key = byBook.first(where: { entry in entry.value.id == id })?.key {
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
        let capturedUserId = userId
        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { capturedUserId })
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
        viewModel: LibraryRootPreviewFixtures.makeViewModel(books: LibraryRootPreviewFixtures.populated),
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in }
    )
}

#Preview("Root - empty") {
    LibraryRootView(
        viewModel: LibraryRootPreviewFixtures.makeViewModel(books: []),
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in }
    )
}

#Preview("Root - with settings button") {
    LibraryRootView(
        viewModel: LibraryRootPreviewFixtures.makeViewModel(books: LibraryRootPreviewFixtures.populated),
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in },
        onShowSettings: { }
    )
}

#Preview("Root - dark mode") {
    LibraryRootView(
        viewModel: LibraryRootPreviewFixtures.makeViewModel(books: LibraryRootPreviewFixtures.populated),
        importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
        onOpenBook: { _ in }
    )
    .preferredColorScheme(.dark)
}
