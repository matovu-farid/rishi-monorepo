@testable import rishi
import Foundation
import Testing




/// Mac import-silent-failure regression (cover-images-missing / Catalyst
/// picker delegate drop). The Catalyst delegate-drop itself needs a running
/// UI and cannot be reproduced in a unit test; the actual delivery fix is the
/// `.fileImporter` switch in `LibraryRootView`. These tests lock the part that
/// IS testable: the import-through-VM pipeline (`importPicked`) routes through
/// `ImportCoordinator`, refreshes the library, and surfaces a user-visible
/// error so import is never silent again.
@MainActor
@Suite("LibraryViewModel importPicked")
struct LibraryViewModelImportPickedTests {

    private func makeFixture(root: URL) -> (LibraryViewModel, UUID) {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        let positionStore = InMemoryPositionStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160)),
                "epub": EpubCoverExtractor()
            ]
        )
        let coordinator = ImportCoordinator(
            storage: storage,
            currentUserId: { userId }
        )
        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: coordinator
        )
        return (vm, userId)
    }

    @Test("importPicked with a valid PDF adds the book and leaves importError nil")
    func importPicked_success() async throws {
        let root = URL.temporaryDirectory
            .appendingPathComponent("LVMImportPicked-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = URL.temporaryDirectory
            .appendingPathComponent("LVMImportPicked-ok-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let srcPDF = srcDir.appendingPathComponent("valid.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)

        let (vm, _) = makeFixture(root: root)
        await vm.importPicked([srcPDF])

        #expect(vm.books.count == 1)
        #expect(vm.importError == nil)
    }

    @Test("importPicked that imports nothing surfaces a non-nil importError")
    func importPicked_silentFailureRevealed() async throws {
        let root = URL.temporaryDirectory
            .appendingPathComponent("LVMImportPicked-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, _) = makeFixture(root: root)
        // A .pdf URL pointing at a file that does not exist — passes the
        // extension allow-list but storage.importBook throws on the copy.
        let missing = URL.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")

        await vm.importPicked([missing])

        #expect(vm.books.isEmpty)
        #expect(vm.importError != nil, "import that produced no books must reveal a user-facing error")
    }

    @Test("importPicked with empty selection is a no-op with no error")
    func importPicked_empty() async throws {
        let root = URL.temporaryDirectory
            .appendingPathComponent("LVMImportPicked-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (vm, _) = makeFixture(root: root)
        let outcomes = await vm.importPicked([])

        #expect(outcomes.isEmpty)
        #expect(vm.books.isEmpty)
        #expect(vm.importError == nil)
    }
}
