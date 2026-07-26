import Foundation



/// Calls `/api/devices/register` exactly once after sign-in so the worker can
/// emit silent pushes to this device (SYNC-06). The actor caches the
/// hex-encoded token of the last successful registration; identical
/// re-registrations are no-ops so a launch-loop or `application(_:didRegister
/// ForRemoteNotificationsWithDeviceToken:)` callback storm doesn't fan out
/// duplicate POSTs.
///
/// End-to-end push emission lands in WORKER-TICKETS Ticket 3.
public actor APNsDeviceRegistrar {

    private let workerClient: WorkerClient
    private let bundleId: String
    private var registeredHex: String?

    public init(workerClient: WorkerClient, bundleId: String = "org.fidexa.rishi") {
        self.workerClient = workerClient
        self.bundleId = bundleId
    }

    /// Register the APNs token. Idempotent against the same token bytes.
    public func register(token: Data, platform: String, appVersion: String) async throws {
        let hex = Self.tokenHexString(from: token)
        if hex == registeredHex {
            Log.event("sync.device.register.skipped", level: .info, data: ["reason": "duplicate-token"])
            return
        }
        let body = DevicesRegisterEndpoint.Body(
            deviceToken: hex,
            platform: platform,
            appVersion: appVersion,
            bundleId: bundleId,
            topic: bundleId
        )
        _ = try await workerClient.send(DevicesRegisterEndpoint(body: body))
        registeredHex = hex
        Log.event("sync.device.registered", level: .info, data: [
            "platform": platform,
            "app_version": appVersion,
        ])
    }

    /// Lowercase hex of `data`. APNs token bytes round-trip directly to
    /// the wire-format string the worker expects.
    public static func tokenHexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
