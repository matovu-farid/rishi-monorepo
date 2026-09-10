import Foundation

#if DEBUG

/// Local-only voice transport used by UI tests. It models a connected
/// realtime peer without opening WebRTC or contacting the Worker, allowing the
/// app's presenter and voice surface to be exercised deterministically.
final class UITestRealtimeClient: RealtimeClientAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var status: RealtimeConnectionStatus = .disconnected

    var providerCallId: String? { "ui-test-provider-call" }

    func prewarm() async {}

    func cancelPrewarm() async {}

    func connect(
        ephemeralKey: String,
        bookContext: BookContextSnapshot?,
        language: String?,
        deferMicCapture: Bool
    ) async throws {
        lock.withLock { status = .connected }
    }

    func setMicCaptureEnabled(_ enabled: Bool) async {}

    func cancelCurrentResponse() async {}

    func disconnect() async {
        lock.withLock { status = .disconnected }
    }

    func currentStatus() async -> RealtimeConnectionStatus {
        lock.withLock { status }
    }

    func errorStream() -> AsyncStream<RealtimeClientError> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func sendToolResult(callId: String, payload: String) async throws {}
}

struct UITestVoiceSessionCoordinator: VoiceSessionCoordinating {
    func startSession(
        language: String?,
        bookContext: BookContextSnapshot?
    ) async throws -> StartedVoiceSession {
        StartedVoiceSession(
            rishiSessionId: "ui-test-rishi-session",
            nonce: "ui-test-nonce",
            clientSecret: "ui-test-client-secret",
            capIntervals: 1,
            realtimeModel: "ui-test-model"
        )
    }

    func registerCall(
        rishiSessionId: String,
        callId: String,
        nonce: String
    ) async throws {}

    func endSession(rishiSessionId: String) async throws {}

    func endActiveSessionIfAny() async throws -> String? { nil }
}

final class UITestMicPermissionGate: MicPermissionGate, @unchecked Sendable {
    var currentDecision: MicPermissionDecision { .granted }

    func request() async -> MicPermissionDecision { .granted }
}

#endif
