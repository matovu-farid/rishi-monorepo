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

    @Test("SyncChangesResponse decodes a representative fixture")
    func syncChangesResponseDecodes() throws {
        let json = """
        {
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
    }

    @Test("SyncPushEndpoint body encodes snake_case updated_at")
    func syncPushBodyEncodesSnakeCase() throws {
        let payload = SyncOpaqueJSON(data: Data("{\"foo\":\"bar\"}".utf8))
        let body = SyncPushEndpoint.Body(changes: [
            SyncChange(
                kind: "highlight",
                id: UUID(),
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
    }

    @Test("SyncPushEndpoint path + method are pinned")
    func syncPushPathAndMethod() {
        let endpoint = SyncPushEndpoint(body: .init(changes: []))
        #expect(endpoint.path == "/api/sync/push")
        #expect(endpoint.method == .POST)
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
