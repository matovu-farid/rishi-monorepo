import Foundation
@testable import RishiVoice

/// Test fake conforming to `RealtimeClientAPI`. Records connect/disconnect
/// calls and lets the test drive transcript + error events into the streams.
///
/// Plan 10-03's `RealtimeVoiceSession` actor tests construct this fake,
/// inject events, and verify the actor's reaction (status transitions,
/// MessageStore writes, error surfacing). No WebRTC, no SDK, no network.
///
/// `@unchecked Sendable` + `NSLock`: AsyncStream continuations are not Sendable
/// across actor hops in Swift 6 strict concurrency, so we manage them under
/// a non-async lock. All call counts are also lock-guarded.
public final class FakeRealtimeClient: RealtimeClientAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var _status: RealtimeConnectionStatus = .disconnected
    private var _connectCalls: [String] = []   // ephemeral keys received, in order
    private var _disconnectCalls = 0
    private var _connectShouldThrow: Error?

    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?

    public init() {}

    // MARK: - Test inspection

    /// Ephemeral keys passed to `connect(ephemeralKey:)`, in call order.
    public var connectCalls: [String] {
        lock.withLock { _connectCalls }
    }

    /// Number of times `disconnect()` was called.
    public var disconnectCalls: Int {
        lock.withLock { _disconnectCalls }
    }

    // MARK: - Test drivers

    /// Cause the next `connect()` call to throw `error`. Cleared after one use.
    public func failNextConnect(with error: Error) {
        lock.withLock { _connectShouldThrow = error }
    }

    /// Drive a transcript event through the fake's stream. No-op if no
    /// transcript stream has been requested yet.
    public func inject(transcript event: RealtimeTranscriptEvent) {
        let continuation: AsyncStream<RealtimeTranscriptEvent>.Continuation? =
            lock.withLock { transcriptContinuation }
        continuation?.yield(event)
    }

    /// Drive a server error through the fake's stream. No-op if no error
    /// stream has been requested yet.
    public func inject(error: RealtimeClientError) {
        let continuation: AsyncStream<RealtimeClientError>.Continuation? =
            lock.withLock { errorContinuation }
        continuation?.yield(error)
    }

    /// Force the status snapshot to a new value (does NOT auto-yield events).
    public func setStatus(_ status: RealtimeConnectionStatus) {
        lock.withLock { _status = status }
    }

    // MARK: - RealtimeClientAPI

    public func connect(ephemeralKey: String) async throws {
        let throwError: Error? = lock.withLock {
            let e = _connectShouldThrow
            _connectShouldThrow = nil
            _connectCalls.append(ephemeralKey)
            return e
        }
        if let throwError { throw throwError }
        lock.withLock { _status = .connected }
    }

    public func disconnect() async {
        let (errCont, txCont): (
            AsyncStream<RealtimeClientError>.Continuation?,
            AsyncStream<RealtimeTranscriptEvent>.Continuation?
        ) = lock.withLock {
            _disconnectCalls += 1
            _status = .disconnected
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            return (e, t)
        }
        errCont?.finish()
        txCont?.finish()
    }

    public func currentStatus() async -> RealtimeConnectionStatus {
        lock.withLock { _status }
    }

    public func errorStream() -> AsyncStream<RealtimeClientError> {
        AsyncStream { continuation in
            lock.withLock { errorContinuation = continuation }
        }
    }

    public func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> {
        AsyncStream { continuation in
            lock.withLock { transcriptContinuation = continuation }
        }
    }
}
