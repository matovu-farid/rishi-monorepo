import Foundation
import RishiCore
import RishiLogging

/// The reconnect engine extracted from `RealtimeVoiceSession` (plan 34-13).
/// Single responsibility: detect a sustained `.disconnected` drop and run the
/// Spike-B backoff reconnect ladder, driving status changes back into the owning
/// session through a small callback surface.
///
/// `RealtimeVoiceSession` keeps the FSM, audio-mode acquisition, and responder
/// spawn; it constructs ONE `ReconnectController` internally (so the session's
/// public `init` is unchanged) and forwards its four reconnect knobs.
///
/// Behavior preserved exactly: same 10Hz status poll, same multi-sample
/// `confirmDisconnect` debounce, same 1s/2s/4s backoff ladder + key re-fetch,
/// same `isEnding` race guards (read via the injected `isEnding` probe).
actor ReconnectController {

    /// Callbacks into the owning session. Each is `@Sendable async` so the
    /// controller (an actor) can drive the session (also an actor) without
    /// holding a strong reference that outlives the session.
    struct Callbacks: Sendable {
        /// Probe the session's `isEnding` flag — true once `end()` is in flight,
        /// at which point the controller must abandon any reconnect work.
        let isEnding: @Sendable () async -> Bool
        /// Session should apply `.reconnecting(attempt:)`.
        let onReconnecting: @Sendable (Int) async -> Void
        /// A reconnect attempt succeeded — session should apply `.live` and
        /// re-arm status observation (which the session re-points at this
        /// controller).
        let onReconnected: @Sendable (Int) async -> Void
        /// All attempts exhausted — session should release the audio mode and
        /// fail with `.networkLost`.
        let onExhausted: @Sendable () async -> Void
    }

    private let client: any RealtimeClientAPI
    private let keyFetcher: any EphemeralKeyFetching
    private let bookContext: BookContextSnapshot?
    private let backoff: @Sendable (Int) -> Duration
    private let maxReconnects: Int
    private let disconnectConfirmations: Int
    private let confirmationInterval: Duration
    private let callbacks: Callbacks

    private var statusObservationTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init(
        client: any RealtimeClientAPI,
        keyFetcher: any EphemeralKeyFetching,
        bookContext: BookContextSnapshot? = nil,
        backoff: @escaping @Sendable (Int) -> Duration,
        maxReconnects: Int,
        disconnectConfirmations: Int,
        confirmationInterval: Duration,
        callbacks: Callbacks
    ) {
        self.client = client
        self.keyFetcher = keyFetcher
        self.bookContext = bookContext
        self.backoff = backoff
        self.maxReconnects = maxReconnects
        self.disconnectConfirmations = disconnectConfirmations
        self.confirmationInterval = confirmationInterval
        self.callbacks = callbacks
    }

    /// Start (or restart) the 10Hz status poll. Called by the session on
    /// initial `.live` and re-armed after a successful reconnect.
    func startStatusObservation() {
        statusObservationTask?.cancel()
        // KEEP: poll runs on the controller actor's executor at 10Hz to detect
        // reconnect-eligible disconnects. The Realtime SDK does not expose a
        // status stream today (Spike B confirmed status is a property).
        statusObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let status = await self.client.currentStatus()
                if status == .disconnected, await self.confirmDisconnect() {
                    await self.handleTransientDisconnect()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Cancel both the status-observation and reconnect tasks. Called from the
    /// session's `end()`.
    func cancel() {
        statusObservationTask?.cancel()
        statusObservationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Re-polls the client status to confirm a `.disconnected` reading is a
    /// real, sustained drop rather than a single transient sample. Returns
    /// `true` only if every confirming poll ALSO reads `.disconnected`; a
    /// single recovery to `.connected`/`.connecting` aborts (returns `false`)
    /// so a healthy session is never torn down and reconnected.
    func confirmDisconnect() async -> Bool {
        for _ in 0..<disconnectConfirmations {
            if await callbacks.isEnding() { return false }
            try? await Task.sleep(for: confirmationInterval)
            if await callbacks.isEnding() { return false }
            if await client.currentStatus() != .disconnected { return false }
        }
        return true
    }

    private func handleTransientDisconnect() async {
        // If end() is already in flight, ignore the disconnect — the explicit
        // teardown owns the termination path.
        if await callbacks.isEnding() { return }
        Log.event("voice.session.disconnect.transient", level: .warning)
        for attempt in 1...maxReconnects {
            if await callbacks.isEnding() { return }
            await callbacks.onReconnecting(attempt)
            try? await Task.sleep(for: backoff(attempt))
            if await callbacks.isEnding() { return }
            // Refresh the ephemeral key — secrets are short-lived. If the key
            // fetch fails on reconnect, count it as a failed attempt.
            let newKey: EphemeralKey
            do {
                newKey = try await keyFetcher.fetch(language: "en")
            } catch {
                continue
            }
            do {
                try await client.connect(ephemeralKey: newKey.secret, bookContext: bookContext)
                await callbacks.onReconnected(attempt)
                Log.event("voice.session.reconnected", level: .info, data: [
                    "attempt": String(attempt),
                ])
                return
            } catch {
                continue
            }
        }
        // All reconnect attempts failed.
        await callbacks.onExhausted()
    }
}
