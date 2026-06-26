























#if DEBUG
import Foundation
import RishiCore
import RishiAPI
import RishiVoice




final class UITestFakeRealtimeClient: RealtimeClientAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var _status: RealtimeConnectionStatus = .disconnected

    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?

    init() {}

    func connect(ephemeralKey: String) async throws {
        
        
        
        lock.withLock { _status = .connecting }
        try? await Task.sleep(for: .milliseconds(120))
        lock.withLock { _status = .connected }
    }

    func disconnect() async {
        let (errCont, txCont, tcCont): (
            AsyncStream<RealtimeClientError>.Continuation?,
            AsyncStream<RealtimeTranscriptEvent>.Continuation?,
            AsyncStream<RealtimeToolCallEvent>.Continuation?
        ) = lock.withLock {
            _status = .disconnected
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            return (e, t, tc)
        }
        errCont?.finish()
        txCont?.finish()
        tcCont?.finish()
    }

    func currentStatus() async -> RealtimeConnectionStatus {
        
        
        
        
        lock.withLock { _status }
    }

    func errorStream() -> AsyncStream<RealtimeClientError> {
        AsyncStream { continuation in
            lock.withLock { errorContinuation = continuation }
        }
    }

    func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> {
        AsyncStream { continuation in
            lock.withLock { transcriptContinuation = continuation }
        }
    }

    func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> {
        AsyncStream { continuation in
            lock.withLock { toolCallContinuation = continuation }
        }
    }

    func sendToolResult(callId: String, payload: String) async throws {
        
    }
}



struct UITestFakeEphemeralKeyFetcher: EphemeralKeyFetching {
    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        EphemeralKey(secret: "uitest-fake-ephemeral-secret", sessionId: "uitest-fake-session")
    }
}






struct UITestGrantedMicGate: MicPermissionGate {
    func request() async -> MicPermissionDecision { .granted }
}
#endif
