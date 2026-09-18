import Foundation
import Testing
@testable import rishi

@Suite("E2E process registration")
struct E2EProcessRegistrationTests {
    @Test("gate is inactive without complete live E2E configuration")
    func testAppRegistrationGateIsInactiveWithoutCompleteLiveE2EConfiguration() throws {
        var called = false
        let result = try E2EProcessRegistration.registerAppIfConfigured(
            environment: ["RISHI_E2E_RUN_ID": "run-1"],
            pid: 41,
            bundleIdentifier: "org.fidexa.rishi",
            exchange: { _, _ in called = true; return Data() }
        )
        #expect(result == .inactive)
        #expect(!called)
    }

    @Test("app client uses bounded newline-delimited relay JSON framing")
    func testAppClientUsesBoundedNewlineDelimitedRelayJSONFraming() throws {
        var captured = Data()
        var capturedLimit = 0
        let result = try E2EProcessRegistration.registerAppIfConfigured(
            environment: Self.environment,
            pid: 42,
            bundleIdentifier: "org.fidexa.rishi",
            exchange: { request, limit in
                captured = request
                capturedLimit = limit
                return Data("{\"ok\":true}\n".utf8)
            }
        )
        #expect(result == .registered)
        #expect(captured.last == 10)
        #expect(String(decoding: captured.dropLast(), as: UTF8.self).contains("\"op\":\"register-app\""))
        #expect(capturedLimit == 1_048_576)
    }

    @Test("registration sends its own pid, app kind, role, bundle, and nonce")
    func exactMetadata() throws {
        var object: [String: Any] = [:]
        _ = try E2EProcessRegistration.registerAppIfConfigured(
            environment: Self.environment,
            pid: 43,
            bundleIdentifier: "org.fidexa.rishi",
            exchange: { request, _ in
                object = try #require(JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any])
                return Data("{\"ok\":true}\n".utf8)
            }
        )
        #expect(object["pid"] as? Int == 43)
        #expect(object["kind"] as? String == "app")
        #expect(object["role"] as? String == "owner")
        #expect(object["bundleIdentifier"] as? String == "org.fidexa.rishi")
        #expect(object["nonce"] as? String == "app-nonce")
    }

    private static let environment = [
        "RISHI_UITEST": "1",
        "RISHI_E2E_REAL_AUTH": "1",
        "RISHI_E2E_RENDEZVOUS_HOST": "127.0.0.1",
        "RISHI_E2E_RENDEZVOUS_PORT": "4321",
        "RISHI_E2E_RENDEZVOUS_SECRET": "secret",
        "RISHI_E2E_RUN_ID": "run-1",
        "RISHI_E2E_ROLE": "owner",
        "RISHI_E2E_PROCESS_KIND": "app",
        "RISHI_E2E_APP_REGISTRATION_NONCE": "app-nonce",
    ]
}
