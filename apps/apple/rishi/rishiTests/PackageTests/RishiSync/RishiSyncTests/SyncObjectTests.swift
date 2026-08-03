@testable import rishi
import Foundation
import Testing

@Suite("SyncObject canonical projection")
struct SyncObjectTests {
    @Test("change ordering and payload key ordering do not change the digest")
    func canonicalDigestIsOrderIndependent() throws {
        let first = SyncChange(
            kind: "book",
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            payload: SyncOpaqueJSON(data: Data(#"{"b":2,"a":1}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4),
            deleted: false
        )
        let second = SyncChange(
            kind: "highlight",
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            payload: SyncOpaqueJSON(data: Data(#"{"a":1,"b":2}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 3),
            deleted: false
        )

        let left = try SyncObject(changes: [first, second]).canonicalHash()
        let right = try SyncObject(changes: [second, first]).canonicalHash()
        #expect(left == right)
    }

    @Test("canonical hashing preserves JSON number and boolean types")
    func canonicalHashDistinguishesNumbersFromBooleans() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let number = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"value":1}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4),
            deleted: false
        )
        let boolean = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"value":true}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4),
            deleted: false
        )

        #expect(try SyncObject(changes: [number]).canonicalHash() != SyncObject(changes: [boolean]).canonicalHash())
    }

    @Test("timestamps do not affect the canonical digest")
    func timestampDifferencesDoNotAffectCanonicalDigest() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let first = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"X","created_at":"2026-08-02T00:00:00.000Z","nested":{"updated_at":"2026-08-02T00:00:00.000Z","value":1}}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4),
            deleted: false
        )
        let second = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"X","created_at":"2026-08-03T00:00:00.000Z","nested":{"updated_at":"2026-08-03T00:00:00.000Z","value":1}}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            deleted: false
        )

        #expect(try SyncObject(changes: [first]).canonicalHash() == SyncObject(changes: [second]).canonicalHash())
    }

    @Test("diff reports meaningful fields but ignores timestamp fields")
    func diffReportsNonTimestampFields() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let remote = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"remote","created_at":"2026-08-02T00:00:00.000Z"}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4),
            deleted: false
        )
        let client = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"client","created_at":"2026-08-03T00:00:00.000Z"}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            deleted: false
        )

        #expect(SyncObject(changes: [remote]).diff(against: SyncObject(changes: [client])) == [
            "book:11111111-1111-4111-8111-111111111111.payload.title",
        ])
    }

    @Test("diff compares scalar JSON payloads without crashing")
    func diffComparesScalarPayloadsSafely() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let remote = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"\"Daniel J. Velleman\""#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4),
            deleted: false
        )
        let client = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"\"Daniel J. Velleman\""#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            deleted: false
        )

        #expect(SyncObject(changes: [remote]).diff(against: SyncObject(changes: [client])).isEmpty)
    }

    @Test("diff reports scalar value and type differences")
    func diffReportsScalarDifferences() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let remote = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data("true".utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 4),
            deleted: false
        )
        let client = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data("1".utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            deleted: false
        )

        #expect(SyncObject(changes: [remote]).diff(against: SyncObject(changes: [client])) == [
            "book:11111111-1111-4111-8111-111111111111.payload",
        ])
    }

    @Test("a missing Worker hash is compatibility, not a mismatch")
    func missingRemoteHashIsAccepted() throws {
        let object = SyncObject(changes: [], remoteHash: nil)
        #expect(try object.matchesRemoteHash())
    }

    @Test("local changes win equal timestamp conflicts")
    func localMergeWinsTies() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let remote = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"remote"}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 9),
            deleted: false
        )
        let local = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"local"}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 9),
            deleted: true
        )

        let merged = SyncObject(changes: [remote]).merging(localChanges: [local])
        #expect(merged.changes.count == 1)
        #expect(merged.changes[0].deleted)
    }

    @Test("duplicate remote entities are resolved without crashing")
    func duplicateRemoteEntitiesAreResolved() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let live = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data(#"{"title":"live"}"#.utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 9),
            deleted: false
        )
        let tombstone = SyncChange(
            kind: "book",
            id: id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: 9),
            deleted: true
        )

        let merged = SyncObject(changes: [live, tombstone]).merging(localChanges: [])
        #expect(merged.changes.count == 1)
        #expect(merged.changes[0].deleted)
    }
}
