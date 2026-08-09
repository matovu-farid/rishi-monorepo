@testable import rishi
import Foundation
import Testing

@Suite("Sync integrity verification")
struct SyncIntegrityVerifierTests {
    private let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func change(_ title: String) -> SyncChange {
        SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"\#(title)"}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 10),
            deleted: false
        )
    }

    @Test("remote hash is checked against the remote-only object")
    func remoteHashDoesNotIncludePendingLocalProjection() throws {
        let remote = SyncObject(changes: [change("remote")])
        let remoteHash = try remote.canonicalHash()
        let remoteWithHash = SyncObject(changes: remote.changes, remoteHash: remoteHash)
        let local = SyncObject(changes: [change("local")])

        let observation = try SyncIntegrityVerifier().observe(
            remote: remoteWithHash,
            local: local,
            pendingLocalCount: 0,
            scope: .incremental,
            hashVersion: "sync-json-v1",
            projectionComplete: true
        )

        #expect(observation.classification == .hashMatch)
        #expect(observation.diffPaths == [
            "book:11111111-1111-4111-8111-111111111111.payload.title",
        ])
    }

    @Test("pending local changes defer the semantic verdict")
    func pendingLocalChangesAreAdvisory() throws {
        let remote = SyncObject(changes: [change("remote")])
        let observation = try SyncIntegrityVerifier().observe(
            remote: SyncObject(changes: remote.changes, remoteHash: try remote.canonicalHash()),
            local: SyncObject(changes: [change("local")]),
            pendingLocalCount: 1,
            scope: .incremental,
            hashVersion: "sync-json-v1",
            projectionComplete: true
        )

        #expect(observation.classification == .deferredPendingLocalChanges)
        #expect(observation.diffPaths.count == 1)
    }

    @Test("truncated projection is classified without exposing values")
    func truncatedProjectionIsAdvisoryAndRedacted() throws {
        let observation = try SyncIntegrityVerifier().observe(
            remote: SyncObject(changes: [change("private title")], remoteHash: "bad"),
            local: nil,
            pendingLocalCount: 0,
            scope: .incremental,
            hashVersion: "sync-json-v1",
            projectionComplete: false
        )

        #expect(observation.classification == .incompleteProjection)
        #expect(observation.diffPaths.isEmpty)
        #expect(observation.redactedDescription.contains("private title") == false)
    }
}
