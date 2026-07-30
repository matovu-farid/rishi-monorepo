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
    var errorPump: Task<Void, Never>? {
        get { lock.withLock { _errorPump } }
        set { lock.withLock { _errorPump = newValue } }
    }
    var transcriptPump: Task<Void, Never>? {
        get { lock.withLock { _transcriptPump } }
        set { lock.withLock { _transcriptPump = newValue } }
    }
    var toolCallPump: Task<Void, Never>? {
        get { lock.withLock { _toolCallPump } }
        set { lock.withLock { _toolCallPump = newValue } }
    }

    private var _errorPump: Task<Void, Never>?
    private var _transcriptPump: Task<Void, Never>?
    private var _toolCallPump: Task<Void, Never>?

    /// Tool-call dedupe: tracks which `callId`s have already been emitted to
    /// the tool-call stream this generation. The token check and insertion are
    /// atomic so a cancelled old pump cannot mutate the next generation's set.
    private let callIDDeduper = RealtimeEventPumpCallIDDeduper()
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
        lock.withLock {
            _errorPump != nil || _transcriptPump != nil || _toolCallPump != nil
        }
    }

    /// Cancel + nil all three pump Tasks. Dedupe state is cleared by `start()`
    /// for the next generation and by `reset()` on full disconnect.
    func cancel() {
        lock.withLock {
            _errorPump?.cancel(); _errorPump = nil
            _transcriptPump?.cancel(); _transcriptPump = nil
            _toolCallPump?.cancel(); _toolCallPump = nil
        }
    }

    /// Clear the dedupe set. Called from the adapter's `disconnect()` under the
    /// adapter's lock-guarded teardown, matching the prior `emittedCallIds.removeAll()`.
    func reset() {
        lock.withLock {
            callIDDeduper.reset()
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
        errorContinuation: @escaping @Sendable (RealtimeClientError) -> Void,
        transcriptContinuation: @escaping @Sendable (RealtimeTranscriptEvent) -> Void,
        toolCallContinuation: @escaping @Sendable (RealtimeToolCallEvent) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Publishing the handles and cancelling the previous generation are
        // one transaction. This prevents teardown from observing an empty
        // slot after a Task has been created but before its handle is stored.
        _errorPump?.cancel()
        _transcriptPump?.cancel()
        _toolCallPump?.cancel()
        let generation = callIDDeduper.beginGeneration()

        let dispatcher = self.dispatcher
        let clock = ContinuousClock()

        // Error pump — direct forward from the SDK's AsyncStream<ServerError>.
        // The explicit MainActor.run hops are required to read the SDK's
        // @MainActor @Observable `convo.errors` / `convo.entries`.
        let newErrorPump = Task {
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
                errorContinuation(mapped)
                if Task.isCancelled { return }
            }
        }

        // Transcript pump — `entries` is `@MainActor` `@Observable`. The SDK
        // mutates message content/status in place, so re-scan the full array.
        // Downstream (`VoiceTranscriptBridge`) expects **deltas** (`+=`), so
        // emit only the suffix grown since the last emission for this index.
        let newTranscriptPump = Task {
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
                    transcriptContinuation(event)
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
        let newToolCallPump = Task { [weak self] in
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
                        guard self.callIDDeduper.isCurrent(generation) else {
                            return (true, false)
                        }
                        let alreadyEmitted = self.callIDDeduper.isEmitted(
                            fc.callId,
                            generation: generation
                        )
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
                    guard self.callIDDeduper.markEmittedIfCurrent(
                        fc.callId,
                        generation: generation
                    ) else { continue }
                    let event = RealtimeToolCallEvent(
                        callId: fc.callId,
                        name: fc.name,
                        argumentsJSON: fc.arguments
                    )
                    Log.event("voice.tool.sdk.emitted", level: .info, data: [
                        "callId": event.callId,
                        "name": event.name,
                    ])
                    toolCallContinuation(event)
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }

        _errorPump = newErrorPump
        _transcriptPump = newTranscriptPump
        _toolCallPump = newToolCallPump
    }
}

/// Generation-scoped call-ID dedupe. Its generation check and insertion must
/// be one locked operation: cancellation does not guarantee that an old task
/// stops before its next synchronous statement.
final class RealtimeEventPumpCallIDDeduper: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var emittedCallIds: Set<String> = []

    func beginGeneration() -> UUID {
        lock.withLock {
            generation = UUID()
            emittedCallIds.removeAll()
            return generation
        }
    }

    func reset() {
        lock.withLock {
            generation = UUID()
            emittedCallIds.removeAll()
        }
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        lock.withLock { generation == candidate }
    }

    func isEmitted(_ callId: String, generation candidate: UUID) -> Bool {
        lock.withLock {
            guard generation == candidate else { return true }
            return emittedCallIds.contains(callId)
        }
    }

    func markEmittedIfCurrent(_ callId: String, generation candidate: UUID) -> Bool {
        lock.withLock {
            guard generation == candidate else { return false }
            return emittedCallIds.insert(callId).inserted
        }
    }
}
