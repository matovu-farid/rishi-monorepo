import Foundation
import RealtimeAPI

/// Owns the three SDK→stream polling loops that `RealtimeAPIAdapter` previously
/// inlined in `startPumps(for:)`: the error forward, the transcript snapshot
/// poll, and the tool-call snapshot poll (with per-call dedupe). Single
/// responsibility: drive the SDK `Conversation`'s observable surface into the
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
        lock.withLock { emittedCallIds.removeAll() }
    }

    /// Start the three polling loops for the given `Conversation`, yielding into
    /// the continuations returned by the supplied accessors. The accessors are
    /// invoked per-yield so they read the adapter's CURRENT continuation under
    /// the adapter's own lock — identical to the prior inline code.
    func start(
        for convo: Conversation,
        errorContinuation: @escaping @Sendable () -> AsyncStream<RealtimeClientError>.Continuation?,
        transcriptContinuation: @escaping @Sendable () -> AsyncStream<RealtimeTranscriptEvent>.Continuation?,
        toolCallContinuation: @escaping @Sendable () -> AsyncStream<RealtimeToolCallEvent>.Continuation?
    ) {
        let dispatcher = self.dispatcher

        // Error pump — direct forward from the SDK's AsyncStream<ServerError>.
        // The explicit MainActor.run hops are required to read the SDK's
        // @MainActor @Observable `convo.errors` / `convo.entries`.
        errorPump = Task {
            let errors = await MainActor.run { convo.errors }
            for await error in errors {
                let mapped = RealtimeClientError(
                    code: "server_error",
                    message: String(describing: error)
                )
                errorContinuation()?.yield(mapped)
                if Task.isCancelled { return }
            }
        }

        // Transcript pump — `entries` is `@MainActor` `@Observable`. The SDK
        // doesn't surface a delta-stream, so we poll `entries.count` at ~5Hz
        // and emit a transcript event for each new finalized message.
        transcriptPump = Task {
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
                        transcriptContinuation()?.yield(event)
                    }
                    lastSeenIndex = snapshot.count
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
                for item in snapshot {
                    guard case let .functionCall(fc) = item else { continue }
                    guard let self else { return }
                    let alreadyEmitted: Bool = self.lock.withLock {
                        self.emittedCallIds.contains(fc.callId)
                    }
                    if alreadyEmitted { continue }
                    guard dispatcher.isArgumentsReady(fc: fc) else { continue }
                    self.lock.withLock { _ = self.emittedCallIds.insert(fc.callId) }
                    let event = RealtimeToolCallEvent(
                        callId: fc.callId,
                        name: fc.name,
                        argumentsJSON: fc.arguments
                    )
                    toolCallContinuation()?.yield(event)
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
    }
}
