import Foundation
import RealtimeAPI
import RishiLogging

/// Production impl of `RealtimeClientAPI` backed by `swift-realtime-openai`'s
/// `Conversation` type.
///
/// `Conversation` is `@MainActor`-isolated `@Observable` (see UI/Conversation.swift
/// in the pinned SDK at SHA `46f393d…`). All access to the wrapped instance
/// therefore hops to the main actor. The adapter itself is `@unchecked Sendable`
/// because the optional `conversation` reference is mutated under an `NSLock`
/// from off-main contexts; the stored value is only read on `@MainActor` and
/// reset under the lock during disconnect.
///
/// Transcript pump path (per Plan 10-02 note): the pinned SDK exposes finalized
/// transcripts via `Conversation.entries: [Item]` where `case .message(Item.Message)`
/// carries `[Item.Message.Content]` whose `.text` accessor unifies text +
/// audio-transcript content. The adapter snapshots `entries.count` between
/// SDK ticks and emits a transcript event for each NEW entry. If a future
/// iteration of the SDK switches finalized transcripts back into the
/// `events` stream (`response.audio_transcript.done`, etc.), the snapshot
/// path stays correct because `entries` is the source of truth that the
/// SDK's own `event-handler` writes into.
public final class RealtimeAPIAdapter: RealtimeClientAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var conversation: Conversation?

    // Persistent stream continuations across the adapter's lifetime. New
    // consumers re-call to get a new stream backed by the same continuation
    // slot — finishing on `disconnect()`.
    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?

    // `internal` (not `private`) so the white-box teardown test can assign
    // sentinel pumps and assert they are cancelled + niled, mirroring how
    // `isArgumentsReady` is `internal` for `@testable` tests.
    internal var errorPump: Task<Void, Never>?
    internal var transcriptPump: Task<Void, Never>?
    internal var toolCallPump: Task<Void, Never>?

    /// Tool-call dedupe: tracks which `callId`s have already been emitted to
    /// the tool-call stream this connection. Cleared on `disconnect()`.
    /// Lock-guarded (mutated from the toolCallPump task).
    private var emittedCallIds: Set<String> = []

    public init() {}

    // MARK: - RealtimeClientAPI

    public func connect(ephemeralKey: String) async throws {
        // Single-peer invariant: opening a new peer always closes the old one
        // first. On RECONNECT the session re-calls `connect()` WITHOUT a
        // preceding `disconnect()` (so transcript/tool/error streams stay
        // alive). Without this teardown, the prior `startPumps` Tasks keep
        // polling the OLD `Conversation`, retaining its WebRTC peer + audio —
        // producing two concurrent voices. Tearing down here cancels those
        // pumps and drops the old `Conversation` so its `deinit` closes the
        // peer, without touching the stream continuations.
        teardownActiveConversation()
        Log.event("voice.adapter.connecting", level: .info)
        let convo = await MainActor.run { () -> Conversation in
            Conversation(debug: false) { session in
                // Voice + VAD parity with electron / Spike B (INTEGRATIONS.md:44):
                // server VAD threshold 0.7, silence 700ms, prefix padding 300ms,
                // voice=alloy, PCM 24kHz.
                //
                // Session.AudioFormat exposes only an internal memberwise init,
                // so we round-trip JSON to build it from outside the module —
                // mirrors the spike harness.
                let pcm24k: Session.AudioFormat = {
                    let data = try! JSONSerialization.data(withJSONObject: [
                        "rate": 24000,
                        "type": "pcm",
                    ])
                    return try! JSONDecoder().decode(
                        Session.AudioFormat.self, from: data
                    )
                }()
                let input = Session.Audio.Input(
                    format: pcm24k,
                    noiseReduction: nil,
                    transcription: nil,
                    turnDetection: .serverVad(
                        prefixPaddingMs: 300,
                        silenceDurationMs: 700,
                        threshold: 0.7
                    )
                )
                let output = Session.Audio.Output(
                    voice: .alloy,
                    speed: 1.0,
                    format: pcm24k
                )
                session.audio = Session.Audio(input: input, output: output)
            }
        }
        lock.withLock { self.conversation = convo }
        try await convo.connect(ephemeralKey: ephemeralKey)
        Log.event("voice.adapter.connected", level: .info)
        startPumps(for: convo)
    }

    /// Cancels the active pumps and releases the current `Conversation` so its
    /// `deinit` closes the WebRTC peer. Does NOT touch the stream continuations,
    /// so a reconnect can keep the same transcript/tool/error streams alive.
    /// `internal` for white-box testing (mirrors `isArgumentsReady`).
    internal func teardownActiveConversation() {
        errorPump?.cancel(); errorPump = nil
        transcriptPump?.cancel(); transcriptPump = nil
        toolCallPump?.cancel(); toolCallPump = nil
        // Dropping the last reference to `Conversation` triggers its
        // `deinit { client.disconnect() }`, closing the WebRTC peer.
        lock.withLock { self.conversation = nil }
    }

    public func disconnect() async {
        // Pump + Conversation teardown is the shared single-peer path.
        teardownActiveConversation()

        let (errCont, txCont, tcCont): (
            AsyncStream<RealtimeClientError>.Continuation?,
            AsyncStream<RealtimeTranscriptEvent>.Continuation?,
            AsyncStream<RealtimeToolCallEvent>.Continuation?
        ) = lock.withLock {
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            emittedCallIds.removeAll()
            return (e, t, tc)
        }
        errCont?.finish()
        txCont?.finish()
        tcCont?.finish()

        Log.event("voice.adapter.disconnected", level: .info)
    }

    public func currentStatus() async -> RealtimeConnectionStatus {
        let convo: Conversation? = lock.withLock { self.conversation }
        guard let convo else { return .disconnected }
        // SDK's status enum: .connected | .connecting | .disconnected (no
        // .disconnecting). Read on the main actor since Conversation is
        // @MainActor isolated.
        let raw = await MainActor.run { convo.status }
        switch raw {
        case .connected:    return .connected
        case .connecting:   return .connecting
        case .disconnected: return .disconnected
        }
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

    public func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> {
        AsyncStream { continuation in
            lock.withLock { toolCallContinuation = continuation }
        }
    }

    public func sendToolResult(callId: String, payload: String) async throws {
        let convo: Conversation? = lock.withLock { self.conversation }
        guard let convo else {
            throw RealtimeClientError(
                code: "not_connected",
                message: "Cannot send tool result: not connected"
            )
        }
        let outputId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            try await MainActor.run {
                try convo.send(result: Item.FunctionCallOutput(
                    id: outputId,
                    callId: callId,
                    output: payload
                ))
            }
        } catch {
            throw RealtimeClientError(
                code: "send_failed",
                message: String(describing: error)
            )
        }
        Log.event("voice.tool.result.sent", level: .info, data: [
            "callId": callId,
            "payloadBytes": String(payload.utf8.count),
        ])
    }

    // MARK: - Readiness gate (RESEARCH OQ-Q11-7)

    /// Returns true when an inbound `Item.FunctionCall` is ready to dispatch.
    /// The pinned SDK does NOT explicitly flip `status` to `.completed` when
    /// `responseFunctionCallArgumentsDone` fires (verified by reading the SDK
    /// at `~/Library/.../swift-realtime-openai/Sources/UI/Conversation.swift`).
    /// We accept either signal: explicit `.completed` status OR `arguments`
    /// parses as a valid JSON object.
    ///
    /// `internal` (not `public`) so the white-box test target can drive it
    /// via `@testable import RishiVoice` without exposing it to consumers.
    internal func isArgumentsReady(fc: Item.FunctionCall) -> Bool {
        // Robust to SDK enum case-rename (no direct comparison to .completed
        // because the SDK module is imported lazily by callers).
        if String(describing: fc.status) == "completed" { return true }
        guard let data = fc.arguments.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    // MARK: - Internal pumps

    /// Forward the SDK's server errors + transcript entries into our streams.
    /// Both pumps cancel on `disconnect()`.
    private func startPumps(for convo: Conversation) {
        // Error pump — direct forward from the SDK's AsyncStream<ServerError>.
        // KEEP: nonisolated adapter actor; the explicit MainActor.run hops are
        // required to read the SDK's @MainActor @Observable `convo.errors` /
        // `convo.entries`. Pump loops run on the adapter's executor (off main).
        errorPump = Task { [weak self] in
            let errors = await MainActor.run { convo.errors }
            for await error in errors {
                guard let self else { return }
                let mapped = RealtimeClientError(
                    code: "server_error",
                    message: String(describing: error)
                )
                let cont = self.lock.withLock { self.errorContinuation }
                cont?.yield(mapped)
                if Task.isCancelled { return }
            }
        }

        // Transcript pump — `entries` is `@MainActor` `@Observable`. The SDK
        // doesn't surface a delta-stream, so we poll `entries.count` at ~5Hz
        // and emit a transcript event for each new finalized message. This is
        // the same shape Spike B used (1Hz status polling) — voice chat tail
        // latency tolerates 200ms cadence.
        // KEEP: transcript pump runs on the adapter actor's executor; the
        // 200ms cadence + MainActor.run reads are intentional (Spike B pattern).
        // Observation push refactor deferred to v1.1 ADR backlog (plan 19-12).
        transcriptPump = Task { [weak self] in
            var lastSeenIndex = 0
            while !Task.isCancelled {
                let snapshot: [Item] = await MainActor.run { convo.entries }
                if snapshot.count > lastSeenIndex {
                    for item in snapshot[lastSeenIndex..<snapshot.count] {
                        guard case let .message(msg) = item else { continue }
                        let role: TranscriptRole = (msg.role == .assistant)
                            ? .assistant : .user
                        // Concatenate all .text accessors across content parts.
                        // `.text` unifies `.text`, `.inputText`, and
                        // `.audio(_).transcript` — exactly the surface we need.
                        let text = msg.content
                            .compactMap { $0.text }
                            .joined(separator: "")
                        guard !text.isEmpty else { continue }
                        let isFinal = (msg.status == .completed)
                        let event = RealtimeTranscriptEvent(
                            role: role,
                            content: text,
                            isFinal: isFinal
                        )
                        guard let self else { return }
                        let cont = self.lock.withLock { self.transcriptContinuation }
                        cont?.yield(event)
                    }
                    lastSeenIndex = snapshot.count
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }

        // Tool-call pump — mirrors transcript pump shape but filters `entries`
        // for `case .functionCall(let fc)`. Per RESEARCH Q3, the SDK ingests
        // tool calls into `entries` via `conversationItemCreated` (which
        // appends a not-yet-ready FunctionCall) then mutates the same slot via
        // `responseFunctionCallArgumentsDelta` / `…Done`. We therefore re-scan
        // the FULL entries array each tick (not just newly-appended items) so
        // we catch status flips / argument completion on previously-seen
        // entries. Per-call dedupe via `emittedCallIds` ensures we emit each
        // call exactly once.
        //
        // Cost: O(entries) per tick; entries are bounded per session and the
        // .functionCall guard short-circuits non-call items. 200ms cadence
        // matches transcript pump — voice users tolerate the tail latency.
        toolCallPump = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot: [Item] = await MainActor.run { convo.entries }
                for item in snapshot {
                    guard case let .functionCall(fc) = item else { continue }
                    guard let self else { return }
                    let alreadyEmitted: Bool = self.lock.withLock {
                        self.emittedCallIds.contains(fc.callId)
                    }
                    if alreadyEmitted { continue }
                    guard self.isArgumentsReady(fc: fc) else { continue }
                    self.lock.withLock { _ = self.emittedCallIds.insert(fc.callId) }
                    let event = RealtimeToolCallEvent(
                        callId: fc.callId,
                        name: fc.name,
                        argumentsJSON: fc.arguments
                    )
                    let cont = self.lock.withLock { self.toolCallContinuation }
                    cont?.yield(event)
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
    }
}
