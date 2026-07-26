import Foundation



/// Owns the three SDK→stream polling loops that `RealtimeAPIAdapter` previously
/// inlined in `startPumps(for:)`: the error forward, the transcript snapshot
/// poll, and the tool-call snapshot poll (with per-call dedupe). Single
/// responsibility: drive the SDK `RealtimeConversation`'s observable surface into the
/// adapter's stream continuations.
///
/// `@unchecked Sendable` for the same reason the adapter is: it holds the three
/// pump `Task` handles + the `emittedCallIds` dedupe set, mutated from off-main
/// pump contexts under its own `NSLock`. The adapter owns the continuation slots
/// (under the adapter's lock); the pump reads them through `@Sendable` accessor
/// closures so the continuation locking contract is unchanged.
///
/// Behavior preserved exactly: same 200ms cadence, same `entries`-snapshot
/// transcript path, same full-rescan tool-call dedupe, same MainActor hops.
final class RealtimeEventPump: @unchecked Sendable {

    private let lock = NSLock()

    // `internal` (not `private`) so the white-box teardown test can assign
    // sentinel pumps and assert they are cancelled + niled.
    var errorPump: Task<Void, Never>?
    var transcriptPump: Task<Void, Never>?
    var toolCallPump: Task<Void, Never>?

    /// Tool-call dedupe: tracks which `callId`s have already been emitted to
    /// the tool-call stream this connection. Cleared on `reset()`.
    private var emittedCallIds: Set<String> = []
    /// Tracks which `callId`s we have already logged as "seen" so we do not
    /// spam the console every 200ms while the SDK is still assembling args.
    private var observedCallIds: Set<String> = []
    /// Throttles diagnostic scan logs so we can tell whether the SDK is
    /// surfacing any function-call entries without logging every 200ms tick.
    private var lastToolScanLogAt: ContinuousClock.Instant?

    private let dispatcher: RealtimeToolCallDispatcher

    init(dispatcher: RealtimeToolCallDispatcher = RealtimeToolCallDispatcher()) {
        self.dispatcher = dispatcher
    }

    /// True once any of the three pumps is running (used by tests/teardown).
    var isRunning: Bool {
        errorPump != nil || transcriptPump != nil || toolCallPump != nil
    }

    /// Cancel + nil all three pump Tasks. Does NOT clear `emittedCallIds` — that
    /// is reset by `reset()` on full disconnect, mirroring the prior adapter
    /// split (teardown cancels pumps; disconnect clears dedupe).
    func cancel() {
        errorPump?.cancel(); errorPump = nil
        transcriptPump?.cancel(); transcriptPump = nil
        toolCallPump?.cancel(); toolCallPump = nil
    }

    /// Clear the dedupe set. Called from the adapter's `disconnect()` under the
    /// adapter's lock-guarded teardown, matching the prior `emittedCallIds.removeAll()`.
    func reset() {
        lock.withLock {
            emittedCallIds.removeAll()
            observedCallIds.removeAll()
            lastToolScanLogAt = nil
        }
    }

    /// Start the three polling loops for the given `RealtimeConversation`, yielding into
    /// the continuations returned by the supplied accessors. The accessors are
    /// invoked per-yield so they read the adapter's CURRENT continuation under
    /// the adapter's own lock — identical to the prior inline code.
    func start(
        for convo: RealtimeConversation,
        errorContinuation: @escaping @Sendable () -> AsyncStream<RealtimeClientError>.Continuation?,
        transcriptContinuation: @escaping @Sendable () -> AsyncStream<RealtimeTranscriptEvent>.Continuation?,
        toolCallContinuation: @escaping @Sendable () -> AsyncStream<RealtimeToolCallEvent>.Continuation?
    ) {
        let dispatcher = self.dispatcher
        let clock = ContinuousClock()

        // Error pump — direct forward from the SDK's AsyncStream<ServerError>.
        // The explicit MainActor.run hops are required to read the SDK's
        // @MainActor @Observable `convo.errors` / `convo.entries`.
        errorPump = Task {
            let errors = await MainActor.run { convo.errors }
            for await error in errors {
                Log.event("voice.adapter.server_error", level: .error, data: [
                    "type": error.type,
                    "code": error.code ?? "",
                    "param": error.param ?? "",
                    "message": error.message,
                ])
                let mapped = RealtimeClientError(
                    code: error.code ?? "server_error",
                    message: error.message
                )
                errorContinuation()?.yield(mapped)
                if Task.isCancelled { return }
            }
        }

        // Transcript pump — `entries` is `@MainActor` `@Observable`. The SDK
        // mutates message content/status in place, so re-scan the full array.
        // Downstream (`VoiceTranscriptBridge`) expects **deltas** (`+=`), so
        // emit only the suffix grown since the last emission for this index.
        transcriptPump = Task {
            var lastEmitted: [Int: (text: String, isFinal: Bool)] = [:]
            while !Task.isCancelled {
                let snapshot: [Item] = await MainActor.run { convo.entries }
                for (index, item) in snapshot.enumerated() {
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
                    let prev = lastEmitted[index]
                    if let prev, prev.text == text, prev.isFinal == isFinal {
                        continue
                    }
                    lastEmitted[index] = (text, isFinal)

                    let delta: String
                    if let prev, text.hasPrefix(prev.text) {
                        delta = String(text.dropFirst(prev.text.count))
                    } else {
                        delta = text
                    }
                    // Skip no-op growth; still emit empty+final so the bridge
                    // can flush its buffer when only status flips to completed.
                    if delta.isEmpty, !(isFinal && prev?.isFinal != true) {
                        continue
                    }

                    let event = RealtimeTranscriptEvent(
                        role: role,
                        content: delta,
                        isFinal: isFinal
                    )
                    transcriptContinuation()?.yield(event)
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }

        // Tool-call pump — mirrors transcript pump shape but filters `entries`
        // for `case .functionCall(let fc)`. The SDK ingests tool calls into
        // `entries` via `conversationItemCreated` (which appends a not-yet-ready
        // FunctionCall) then mutates the same slot via
        // `responseFunctionCallArgumentsDelta` / `…Done`. We therefore re-scan
        // the FULL entries array each tick (not just newly-appended items) so we
        // catch status flips / argument completion on previously-seen entries.
        // Per-call dedupe via `emittedCallIds` ensures we emit each call once.
        toolCallPump = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot: [Item] = await MainActor.run { convo.entries }
                if let self {
                    let (toolCallCount, readyCount, shouldLog): (Int, Int, Bool) = self.lock.withLock {
                        let toolCalls = snapshot.compactMap { item -> Item.FunctionCall? in
                            guard case let .functionCall(fc) = item else { return nil }
                            return fc
                        }
                        let toolCallCount = toolCalls.count
                        let readyCount = toolCalls.filter { dispatcher.isArgumentsReady(fc: $0) }.count
                        let now = clock.now
                        let shouldLog: Bool
                        if let last = self.lastToolScanLogAt {
                            shouldLog = now >= last.advanced(by: .seconds(2))
                        } else {
                            shouldLog = true
                        }
                        if shouldLog { self.lastToolScanLogAt = now }
                        return (toolCallCount, readyCount, shouldLog)
                    }
                    if shouldLog {
                        Log.event("voice.tool.sdk.scan", level: .info, data: [
                            "entries": String(snapshot.count),
                            "functionCalls": String(toolCallCount),
                            "readyFunctionCalls": String(readyCount),
                        ])
                    }
                }
                for item in snapshot {
                    guard case let .functionCall(fc) = item else { continue }
                    guard let self else { return }
                    let (alreadyEmitted, firstObserved): (Bool, Bool) = self.lock.withLock {
                        let alreadyEmitted = self.emittedCallIds.contains(fc.callId)
                        let firstObserved = self.observedCallIds.insert(fc.callId).inserted
                        return (alreadyEmitted, firstObserved)
                    }
                    if firstObserved {
                        Log.event("voice.tool.sdk.observed", level: .info, data: [
                            "callId": fc.callId,
                            "name": fc.name,
                            "status": String(describing: fc.status),
                            "argumentsBytes": String(fc.arguments.utf8.count),
                        ])
                    }
                    if alreadyEmitted { continue }
                    guard dispatcher.isArgumentsReady(fc: fc) else { continue }
                    Log.event("voice.tool.sdk.ready", level: .info, data: [
                        "callId": fc.callId,
                        "name": fc.name,
                    ])
                    self.lock.withLock { _ = self.emittedCallIds.insert(fc.callId) }
                    let event = RealtimeToolCallEvent(
                        callId: fc.callId,
                        name: fc.name,
                        argumentsJSON: fc.arguments
                    )
                    Log.event("voice.tool.sdk.emitted", level: .info, data: [
                        "callId": event.callId,
                        "name": event.name,
                    ])
                    toolCallContinuation()?.yield(event)
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
    }
}
