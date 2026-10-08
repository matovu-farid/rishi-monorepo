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
    private let credentialAuthority: SessionCredentialAuthority?
    private var registeredCredential: (lease: CredentialLease, hex: String)?

    public init(workerClient: WorkerClient, bundleId: String = "org.fidexa.rishi") {
        self.workerClient = workerClient
        self.bundleId = bundleId
        credentialAuthority = nil
    }

    init(workerClient: WorkerClient, credentialAuthority: SessionCredentialAuthority,
         bundleId: String = "org.fidexa.rishi") {
        self.workerClient = workerClient
        self.bundleId = bundleId
        self.credentialAuthority = credentialAuthority
    }

    /// Register the APNs token. Idempotent against the same token bytes.
    public func register(token: Data, platform: String, appVersion: String) async throws {
        guard credentialAuthority == nil else { throw CredentialAuthenticationFailure.accountChanged }
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

    /// Scoped deduplication is per installation/epoch, including raw-ID reuse.
    func register(token: Data, platform: String, appVersion: String,
                  credentialContext: CredentialRequestContext) async throws {
        guard let credentialAuthority, workerClient.usesCredentialAuthority(credentialAuthority),
              case .normal(let lease) = credentialContext else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        _ = try credentialAuthority.snapshot(for: credentialContext)
        let hex = Self.tokenHexString(from: token)
        if let registeredCredential, registeredCredential.lease == lease, registeredCredential.hex == hex { return }
        let body = DevicesRegisterEndpoint.Body(deviceToken: hex, platform: platform,
            appVersion: appVersion, bundleId: bundleId, topic: bundleId)
        _ = try await workerClient.send(DevicesRegisterEndpoint(body: body), credentialContext: credentialContext)
        guard credentialAuthority.performIfCurrent(lease, mutation: {
            registeredCredential = (lease, hex)
        }) else { throw CredentialAuthenticationFailure.accountChanged }
    }

    /// Lowercase hex of `data`. APNs token bytes round-trip directly to
    /// the wire-format string the worker expects.
    public static func tokenHexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
