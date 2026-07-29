import Foundation

/// `POST /api/devices/register` — register an APNs device token for silent
/// push wakes (SYNC-06). See Phase 0 WORKER-TICKETS Ticket 3 for the
/// worker-side contract.
///
/// Wire format (sync-v1):
/// ```json
/// {
///   "device_token": "<hex64>",
///   "platform": "ios",
///   "app_version": "1.0.0",
///   "bundle_id": "org.fidexa.rishi",
///   "topic": "org.fidexa.rishi"
/// }
/// ```
public struct DevicesRegisterEndpoint: WorkerEndpointWithBody {
    public typealias Response = DevicesRegisterResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let deviceToken: String     // hex, 64 chars
        public let platform: String        // "ios" | "ipados" | "macos-catalyst"
        public let appVersion: String      // e.g. "1.0.0"
        public let bundleId: String        // "org.fidexa.rishi"
        public let topic: String           // "org.fidexa.rishi"

        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case platform
            case appVersion = "app_version"
            case bundleId   = "bundle_id"
            case topic
        }

        public init(deviceToken: String, platform: String, appVersion: String, bundleId: String, topic: String) {
            self.deviceToken = deviceToken
            self.platform = platform
            self.appVersion = appVersion
            self.bundleId = bundleId
            self.topic = topic
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/devices/register"
    public let requiresDataUseConsent = true
    public let body: Body

    public init(body: Body) { self.body = body }
}

public struct DevicesRegisterResponse: Decodable, Sendable, Equatable {
    public let deviceId: UUID
    public let registeredAt: Date

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case registeredAt = "registered_at"
    }

    public init(deviceId: UUID, registeredAt: Date) {
        self.deviceId = deviceId
        self.registeredAt = registeredAt
    }
}
