@testable import rishi
import Testing
import Foundation


@Suite("Sync + Devices endpoint encoders/decoders")
struct SyncAPIEndpointsTests {

    @Test("SyncChangesEndpoint omits ?since= when nil")
    func syncChangesOmitsSinceWhenNil() {
        let endpoint = SyncChangesEndpoint(since: nil)
        #expect(endpoint.method == .GET)
        #expect(endpoint.path == "/api/sync/changes")
    }

    @Test("SyncChangesEndpoint includes URL-encoded ISO8601 since")
    func syncChangesEncodesISO8601Since() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = SyncChangesEndpoint(since: since)
        #expect(endpoint.path.hasPrefix("/api/sync/changes?since="))
        #expect(endpoint.path.contains("2023"))
    }

    @Test("SyncChangesEndpoint adds an opaque cursor without double encoding")
    func syncChangesEncodesCursorOnce() {
        let cursor = "eyJ2IjoxLCJzY29wZSI6ImluY3JlbWVudGFsIn0"
        let endpoint = SyncChangesEndpoint(cursor: cursor)

        #expect(endpoint.path == "/api/sync/changes?cursor=\(cursor)")
        #expect(!endpoint.path.contains("%25"))
    }

    @Test("SyncChangesEndpoint identifies an initial full recovery page")
    func syncChangesEncodesRecoveryScope() {
        let endpoint = SyncChangesEndpoint(scope: .recovery, cursor: nil)

        #expect(endpoint.path == "/api/sync/changes?scope=full")
    }

    @Test("SyncChangesEndpoint routes the event cursor to the event stream")
    func syncChangesEncodesEventScope() {
        #expect(SyncChangesEndpoint(scope: .events, cursor: nil).path == "/api/sync/events")
        #expect(SyncChangesEndpoint(scope: .events, cursor: "42").path == "/api/sync/events?after=42")
    }

    @Test("SyncChangesResponse decodes a representative fixture")
    func syncChangesResponseDecodes() throws {
        let json = """
        {
          "snapshot_hash": "legacy-hash",
          "snapshot_hash_without_timestamps": "timestamp-free-hash",
          "changes": [
            {
              "kind": "position",
              "id": "11111111-1111-1111-1111-111111111111",
              "payload": { "book_id": "22222222-2222-2222-2222-222222222222", "locator": "pdf-v1:page:7", "percent_complete": 0.42 },
              "updated_at": "2026-06-10T12:34:56.000Z",
              "deleted": false
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SyncChangesResponse.self, from: Data(json.utf8))
        #expect(response.changes.count == 1)
        #expect(response.changes[0].kind == "position")
        #expect(response.changes[0].deleted == false)
        #expect(response.changes[0].payload.data.isEmpty == false)
        #expect(response.snapshotHash == "legacy-hash")
        #expect(response.snapshotHashWithoutTimestamps == "timestamp-free-hash")
        #expect(response.nextCursor == nil)
        #expect(response.hasMore == false)
        #expect(response.cursorScope == nil)
        #expect(response.projectionComplete == true)
        #expect(response.snapshotHashVersion == nil)
    }

    @Test("SyncChangesResponse decodes additive cursor-page metadata")
    func syncChangesResponseDecodesPageMetadata() throws {
        let json = """
        {
          "changes": [],
          "next_cursor": "next-page",
          "has_more": true,
          "cursor_scope": "full",
          "projection_complete": false,
          "snapshot_hash_version": "sync-json-v1"
        }
        """
        let response = try JSONDecoder().decode(SyncChangesResponse.self, from: Data(json.utf8))

        #expect(response.nextCursor == "next-page")
        #expect(response.hasMore)
        #expect(response.cursorScope == .recovery)
        #expect(response.projectionComplete == false)
        #expect(response.snapshotHashVersion == "sync-json-v1")
    }

    @Test("SyncPushEndpoint body encodes snake_case updated_at")
    func syncPushBodyEncodesSnakeCase() throws {
        let payload = SyncOpaqueJSON(data: Data("{\"foo\":\"bar\"}".utf8))
        let operationId = UUID()
        let body = SyncPushEndpoint.Body(changes: [
            SyncChange(
                kind: "highlight",
                id: UUID(),
                operationId: operationId,
                payload: payload,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                deleted: false
            )
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(body)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("\"updated_at\""))
        #expect(str.contains("\"deleted\":false"))
        #expect(str.contains("\"operation_id\":\"(operationId.uuidString)\""))
    }

    @Test("SyncPushEndpoint path + method are pinned")
    func syncPushPathAndMethod() {
        let endpoint = SyncPushEndpoint(body: .init(changes: []))
        #expect(endpoint.path == "/api/sync/push")
        #expect(endpoint.method == .POST)
    }

    @Test("SyncPushResponse decodes additive acceptance state")
    func syncPushResponseDecodesAcceptanceState() throws {
        let json = """
        {
          "accepted_at": 5.0,
          "accepted": false
        }
        """
        let response = try JSONDecoder().decode(SyncPushResponse.self, from: Data(json.utf8))

        #expect(response.accepted == false)
    }

    @Test("SyncPushResponse decodes per-operation outcomes")
    func syncPushResponseDecodesOutcomes() throws {
        let json = """
        {
          "accepted_at": 5.0,
          "accepted": true,
          "outcomes": [{"operation_id":"op-1","status":"applied","sequence":42}]
        }
        """
        let response = try JSONDecoder().decode(SyncPushResponse.self, from: Data(json.utf8))

        #expect(response.outcomes == [SyncPushOutcome(operationId: "op-1", status: "applied", sequence: 42)])
    }

    @Test("SyncPushResponse accepts legacy responses without acceptance state")
    func syncPushResponseDecodesLegacyAcceptance() throws {
        let response = try JSONDecoder().decode(
            SyncPushResponse.self,
            from: Data("{\"accepted_at\":5.0}".utf8)
        )

        #expect(response.accepted == nil)
    }

    @Test("DevicesRegisterEndpoint body uses worker contract snake_case")
    func devicesRegisterBodyShape() throws {
        let body = DevicesRegisterEndpoint.Body(
            deviceToken: String(repeating: "a", count: 64),
            platform: "ios",
            appVersion: "1.0.0",
            bundleId: "org.fidexa.rishi",
            topic: "org.fidexa.rishi"
        )
        let data = try JSONEncoder().encode(body)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("\"device_token\""))
        #expect(str.contains("\"app_version\""))
        #expect(str.contains("\"bundle_id\""))
    }

    @Test("DevicesRegisterEndpoint path + method are pinned")
    func devicesRegisterPathAndMethod() {
        let endpoint = DevicesRegisterEndpoint(body: .init(
            deviceToken: "x",
            platform: "ios",
            appVersion: "1.0.0",
            bundleId: "org.fidexa.rishi",
            topic: "org.fidexa.rishi"
        ))
        #expect(endpoint.path == "/api/devices/register")
        #expect(endpoint.method == .POST)
    }

    @Test("DevicesRegisterResponse decodes worker contract")
    func devicesRegisterResponseDecodes() throws {
        let json = """
        { "device_id": "33333333-3333-3333-3333-333333333333", "registered_at": "2026-06-10T12:00:00.000Z" }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(DevicesRegisterResponse.self, from: Data(json.utf8))
        #expect(response.deviceId == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
    }
}
