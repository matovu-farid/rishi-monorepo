@testable import rishi
import Testing
import Foundation



@Suite("RishiSync package smoke")
struct RishiSync_PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiSync.version == "0.1.0-scaffold")
    }

    @Test("Wire format pinned to sync-v2")
    func wireFormatPinned() {
        // Phase 37-08 bumped sync-v1 -> sync-v2 for the additive `bookmark` kind.
        // Schema changes require bumping this AND keeping a decoder fallback that
        // still accepts prior payloads (SyncPayloadCodecBookmarkTests proves it).
        #expect(RishiSync.wireFormat == "sync-v2")
    }

    @Test("RishiCore Book is reachable from the test target")
    func rishiCoreBookIsReachable() {
        let book = Book(
            userId: UUID(),
            title: "Smoke",
            formatType: .epub,
            fileURL: "Books/smoke/smoke.epub"
        )
        #expect(book.title == "Smoke")
        #expect(book.formatType == .epub)
    }

    @Test("RishiAPI SyncUploadURLEndpoint is reachable from the test target")
    func rishiAPISyncUploadEndpointIsReachable() {
        let endpoint = SyncUploadURLEndpoint(body: .init(key: "books/x.epub", contentType: "application/epub+zip"))
        #expect(endpoint.path == "/api/sync/upload-url")
        #expect(endpoint.method == .POST)
    }

    @Test("SwiftData bootstrap yields an empty sync metadata store")
    func syncMetadataBootstrapYieldsEmptyStore() async throws {
        let store = try SyncMetadataStoreBootstrap.makeStore(inMemory: true)
        #expect(try await store.pendingCount() == 0)
        #expect(try await store.allDirty().isEmpty)
    }
}
