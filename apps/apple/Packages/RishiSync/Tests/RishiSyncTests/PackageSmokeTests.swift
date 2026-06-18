import Testing
import Foundation
@testable import RishiSync
import RishiCore
import RishiAPI
import RishiDB

@Suite("RishiSync package smoke")
struct PackageSmokeTests {

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

    @Test("RishiDB Tables.SyncMetadata column names match v1 schema")
    func syncMetadataColumnsMatchV1Schema() {
        // v1 migration in RishiDB/Schema/Migrations.swift created sync_metadata
        // with these exact column names. RishiSync's SyncMetadataStore (07-02)
        // will write/read against this table — lock the contract here.
        #expect(Tables.SyncMetadata.table == "sync_metadata")
        #expect(Tables.SyncMetadata.entityId == "entity_id")
        #expect(Tables.SyncMetadata.entityType == "entity_type")
        #expect(Tables.SyncMetadata.remoteEtag == "remote_etag")
        #expect(Tables.SyncMetadata.lastSyncedAt == "last_synced_at")
        #expect(Tables.SyncMetadata.dirty == "dirty")
    }
}
