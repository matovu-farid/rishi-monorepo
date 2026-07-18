# Realtime provider call-ID capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Testing override:** This plan deliberately contains NO test-writing steps (explicit user override of the writing-plans skill's default TDD structure). Verify every step with `swift build`/`swift test --package-path <package>` or a per-file typecheck instead of new tests. Do not add tests unless a later plan asks for them.

**Goal:** Make the vendored `swift-realtime-openai` WebRTC connector capture the OpenAI-assigned Realtime `call_id` from the `Location` response header when it creates a WebRTC call, and propagate that value up to a new `RealtimeAPIAdapter.providerCallId` property that a later plan (voice-session-flow-wiring) will read right after a successful `connect()` to register with the Worker.

**Architecture:** `WebRTCConnector.fetchRemoteSDP` already discards everything from the `201` response except the SDP answer body; it starts also reading the `Location` header and returns both values as a small file-private struct. That struct's `providerCallId` threads up, unchanged in shape, through `performHandshake` → `WebRTCConnector.connect(using:)` → `Conversation.connect(using:/ephemeralKey:)` as an added `String?` return value (a pure plumbing change — no new stored/observable state in the vendored package, no protocol changes). `RealtimeAPIAdapter` is the seam where propagation-by-return-value stops and exposure-by-property starts: it captures the returned value from `Conversation.connect(ephemeralKey:)` and stores it on a new lock-guarded `providerCallId` property, which is the only thing downstream RishiVoice code (and the later plan) ever reads.

**Tech Stack:** Swift 6 (strict concurrency), Foundation `URLSession`/`HTTPURLResponse`, the vendored `swift-realtime-openai` package (`Core`/`WebRTC`/`UI` targets), the `RishiVoice` package's `RealtimeAPIAdapter`, `RishiLogging` for adapter-level structured events.

---

## Key decisions (read this before implementing)

1. **Property name: `providerCallId` (`String?`), not `callId`.** The spec's own wording is "provider call ID" (no-card-credit-trial-design.md, Voice flow step 3: "the provider call ID"; pricing-trial-launch-prerequisites-design.md, Voice Chat flow step 4: "captures the OpenAI `call_id`"). `callId` is already taken by two unrelated concepts in this codebase — `Item.FunctionCall.callId` / `Item.FunctionCallOutput.callId` (`swift-realtime-openai/Sources/Core/Models/Item.swift:80,109`) and `RealtimeToolCallEvent.callId` (`RishiVoice/Sources/RishiVoice/Service/RealtimeClientAPI.swift:60`) — both of which identify an OpenAI **function/tool call** inside an active session, a per-turn identifier that has nothing to do with the Realtime **call resource** (the WebRTC/SIP session itself) created by `POST /v1/realtime/calls`. Reusing `callId` for the new value would silently collide with that existing vocabulary throughout `RealtimeEventPump.swift` and `RealtimeToolCallDispatcher.swift`. `providerCallId` is unambiguous and matches spec language.

2. **`Location` header format (confirmed via OpenAI's current docs, July 2026): `Location: /v1/realtime/calls/{call_id}`**, e.g. `/v1/realtime/calls/rtc_abc123`. OpenAI's own webhook/server-controls guide gives the canonical parse: `location.split("/").pop()` — i.e. take the last non-empty path segment. This is a relative path, not an absolute URL, so parsing must not assume a scheme/host. `call_id` values are opaque strings prefixed `rtc_` in all current examples, but the parser must not assume that prefix (OpenAI does not document it as a stable contract).

3. **Propagation mechanism: return-value threading through the vendored package, property exposure at the adapter boundary.** `fetchRemoteSDP` becomes the only place that returns a struct (file-private `RemoteSDPResult`, not the public `RealtimeConnection` name floated in the task prompt — see rationale below). `performHandshake`, `WebRTCConnector.connect(using:)`, `Conversation.connect(using:)`, and `Conversation.connect(ephemeralKey:model:)` each grow a `String?` return value carrying just `providerCallId` (the `remoteSdp` never needs to leave `performHandshake`). This is a pure additive plumbing change: none of these four functions have any caller today besides the next function up the chain and (for the two `Conversation.connect` overloads) `RealtimeAPIAdapter.connect` — confirmed by search across `apps/apple/Packages`. The `RealtimeClientAPI` protocol's `connect(...)` signature is **not** touched (it stays `Void`-returning), so `FakeRealtimeClient` and every existing `RishiVoiceTests` file that calls `fake.connect(ephemeralKey:)` keeps compiling untouched.

   Rejected the public `struct RealtimeConnection { let remoteSdp: String; let providerCallId: String? }` name from the task prompt: it never crosses a module boundary (it is constructed and consumed entirely inside `WebRTCConnector.swift`), so making it `public` (or giving it a name suggesting it represents "a connection", when it actually represents "one fetch-remote-SDP result") would add unused public API surface to a vendored package we're told to touch minimally. `RemoteSDPResult`, `private`, scoped to the one file, says exactly what it is.

4. **Missing/malformed `Location` header on a `201`: capture `nil`, log a presence-only warning, do not throw.** Per the task's framing this is a distinct failure mode from registration failure — the SDP negotiation still succeeded and the call must be allowed to proceed to the WebRTC data-channel-open stage; a later plan's session-lifecycle code decides what "no provider call ID" means for the session. `fetchRemoteSDP` logs via `print(...)` (the vendored `WebRTC` target has no `RishiLogging` dependency and already uses bare `print` for its other non-fatal warnings, e.g. the audio-session-configuration failure at `WebRTCConnector.swift:144` and the undecodable-server-event skip at `WebRTCConnector.swift:203` — this stays consistent with that existing convention rather than introducing a new logging dependency into the vendored target). `RealtimeAPIAdapter.connect` additionally logs a structured `RishiLogging` event when it observes the `nil`, since that is the layer the later plan and production telemetry actually watch.

5. **Never log the raw `call_id` value.** `docs/superpowers/specs/2026-07-17-rishi-pricing-trial-launch-prerequisites-design.md`, Telemetry section: *"Do not record book text, audio, ephemeral secrets, or OpenAI call IDs in general logs."* Every log statement this plan adds logs presence/absence only (`"captured"` / `"missing"`), never the string itself.

6. **`providerCallId` is cleared on every teardown, not just set on connect.** `RealtimeAPIAdapter.teardownActiveConversation()` already runs at the top of every `connect()` (single-peer invariant) and inside `disconnect()`. Clearing `providerCallId` there — before a new handshake starts — means that if a *new* connect attempt fails before it reaches the `Location`-header-reading code, the property correctly reads `nil` instead of leaking the previous session's (or previous connect attempt's) call ID. This matters because `ReconnectController.handleTransientDisconnect()` calls `client.connect(ephemeralKey:...)` again on every reconnect attempt, each of which opens a genuinely new OpenAI Realtime call with a new `call_id` — see the note in "Exports for downstream plans" below.

---

## File structure

No new files. Three existing files change:

- `apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift` — `Location`-header parser, `RemoteSDPResult`, `fetchRemoteSDP`/`performHandshake`/`connect(using:)` return-type changes, `create(connectingTo:)` call-site update.
- `apps/apple/Packages/swift-realtime-openai/Sources/UI/Conversation.swift` — `connect(using:)` / `connect(ephemeralKey:model:)` return-type changes.
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift` — new `providerCallId` property, capture + clear + log wiring inside `connect(...)` and `teardownActiveConversation()`.

---

### Task 1: `Location`-header parsing + `fetchRemoteSDP` struct return

**Files:**
- Modify: `apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift:163-176`

- [ ] **Step 1: Add the file-private result struct and header parser, and rewrite `fetchRemoteSDP` to populate them**

Replace the existing `fetchRemoteSDP` function (current lines 163-176) with:

```swift
private func fetchRemoteSDP(using request: URLRequest, localSdp: String) async throws -> RemoteSDPResult {
    var request = request
    request.httpBody = localSdp.data(using: .utf8)
    request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201, let remoteSdp = String(data: data, encoding: .utf8) else {
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw WebRTCError.invalidEphemeralKey }
        throw WebRTCError.badServerResponse(response)
    }

    let providerCallId = Self.providerCallId(fromLocationHeader: httpResponse.value(forHTTPHeaderField: "Location"))
    if providerCallId == nil {
        // Should not happen on a well-formed 201 from POST /v1/realtime/calls.
        // Capturing failure is distinct from an SDP-negotiation failure: the
        // handshake still succeeded, so we do not throw here. Callers must
        // treat a nil providerCallId as equivalent to a registration failure
        // once they reach the point of registering it with the Rishi backend.
        print("WebRTCConnector: OpenAI Realtime call response was missing/malformed Location header; provider call ID not captured for this call.")
    }

    return RemoteSDPResult(remoteSdp: remoteSdp, providerCallId: providerCallId)
}
```

- [ ] **Step 2: Add the `RemoteSDPResult` struct and the `Location`-header parser**

Add this immediately above `fetchRemoteSDP`, inside the same `private extension WebRTCConnector { ... }` block (the block that already contains `setupLocalAudio`, `configureAudioSession`, and `performHandshake`):

```swift
/// Carries both outputs of `fetchRemoteSDP`: the SDP answer body needed to
/// complete the WebRTC handshake, and the OpenAI-assigned Realtime call ID
/// read from the `Location` response header. File-private — this never
/// crosses the WebRTC module boundary; only `providerCallId` propagates
/// further up via `performHandshake`'s return value.
private struct RemoteSDPResult {
    let remoteSdp: String
    let providerCallId: String?
}
```

Add this as a `static` helper on `WebRTCConnector` itself (place it in the same `private extension WebRTCConnector { ... }` block, next to `configureAudioSession`):

```swift
/// Parses the OpenAI-assigned Realtime call ID from the `Location` header
/// returned by a successful `201` response to `POST /v1/realtime/calls`,
/// e.g. `Location: /v1/realtime/calls/rtc_abc123` -> `"rtc_abc123"`.
/// The header is a relative path, not an absolute URL — this takes the
/// last non-empty `/`-separated path segment rather than assuming a
/// scheme/host. Returns `nil` when the header is absent or has no
/// non-empty segment; that should not happen on a well-formed `201` but
/// is not treated as fatal here (see `fetchRemoteSDP`).
static func providerCallId(fromLocationHeader header: String?) -> String? {
    guard let header,
          let lastSegment = header.split(separator: "/").last,
          !lastSegment.isEmpty
    else { return nil }
    return String(lastSegment)
}
```

- [ ] **Step 3: Verify the file still typechecks in isolation**

Run: `xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift 2>&1 | head -50`

Expected: this single-file typecheck will report unresolved-import errors for `Core`/`LiveKitWebRTC` (it's a package source file, not a standalone script) — that's expected and not the signal to look for. The signal to look for is the ABSENCE of any diagnostic pointing at the lines you just changed (`RemoteSDPResult`, `providerCallId(fromLocationHeader:)`, `fetchRemoteSDP`). Full-package verification happens in Task 4; this step is a fast sanity pass only.

- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift
git commit -m "feat(realtime-connector): capture OpenAI call ID from Location header"
```

(Do not push yet — the change doesn't compile end-to-end until Task 2 updates the callers. Commit now for reviewable history; Task 4 is the actual build gate.)

---

### Task 2: Propagate `providerCallId` through `performHandshake` → `connect(using:)` → `create(connectingTo:)`

**Files:**
- Modify: `apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift:68-77` (`connect(using:)`)
- Modify: `apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift:149-161` (`performHandshake`)
- Modify: `apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift:93-98` (`create(connectingTo:)`)

- [ ] **Step 1: Change `performHandshake` to return the captured `providerCallId`**

Replace the existing `performHandshake` function:

```swift
func performHandshake(using request: URLRequest) async throws {
    let sdp = try await Result { try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil)) }
        .mapError(WebRTCError.failedToCreateSDPOffer)
        .get()

    do { try await connection.setLocalDescription(sdp) }
    catch { throw WebRTCError.failedToSetLocalDescription(error) }

    let remoteSdp = try await fetchRemoteSDP(using: request, localSdp: connection.localDescription!.sdp)

    do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: remoteSdp)) }
    catch { throw WebRTCError.failedToSetRemoteDescription(error) }
}
```

with:

```swift
func performHandshake(using request: URLRequest) async throws -> String? {
    let sdp = try await Result { try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil)) }
        .mapError(WebRTCError.failedToCreateSDPOffer)
        .get()

    do { try await connection.setLocalDescription(sdp) }
    catch { throw WebRTCError.failedToSetLocalDescription(error) }

    let result = try await fetchRemoteSDP(using: request, localSdp: connection.localDescription!.sdp)

    do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: result.remoteSdp)) }
    catch { throw WebRTCError.failedToSetRemoteDescription(error) }

    return result.providerCallId
}
```

- [ ] **Step 2: Change `connect(using:)` to return the captured `providerCallId`**

Replace the existing `connect(using:)` function (currently lines 68-77):

```swift
package func connect(using request: URLRequest) async throws {
    guard connection.connectionState == .new else { return }

    guard AVAudioApplication.shared.recordPermission == .granted else {
        throw WebRTCError.missingAudioPermission
    }

    try await performHandshake(using: request)
    Self.configureAudioSession()
}
```

with:

```swift
/// Connects the WebRTC peer and returns the OpenAI-assigned Realtime call
/// ID captured from the `Location` header (`nil` if the header was
/// missing/malformed on an otherwise-successful handshake, or if this call
/// was a no-op because the peer was already connected/connecting).
@discardableResult
package func connect(using request: URLRequest) async throws -> String? {
    guard connection.connectionState == .new else { return nil }

    guard AVAudioApplication.shared.recordPermission == .granted else {
        throw WebRTCError.missingAudioPermission
    }

    let providerCallId = try await performHandshake(using: request)
    Self.configureAudioSession()
    return providerCallId
}
```

- [ ] **Step 3: Update the one other caller of `connect(using:)` in this file, `create(connectingTo:)`, to discard the new return value**

`create(connectingTo:)` (the static factory satisfying the `Connector` protocol's `create(connectingTo:) async throws -> Self` requirement) doesn't need the captured call ID — protocol callers get a connector instance back, not a call ID, and nothing today reads a call ID off a raw `WebRTCConnector` built this way. Change:

```swift
public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
    let connector = try create()
    try await connector.connect(using: request)
    return connector
}
```

to:

```swift
public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
    let connector = try create()
    _ = try await connector.connect(using: request)
    return connector
}
```

- [ ] **Step 4: Verify with a build (not just typecheck) — this is the first point where the whole `WebRTC` target must compile**

Run: `swift build --package-path apps/apple/Packages/swift-realtime-openai`

Expected: `Build complete!` with no errors. If you see "result of call to 'connect' is unused" anywhere else in this package, you missed a call site — search for it (`rg 'connector\.connect\(using:|client\.connect\(using:' apps/apple/Packages/swift-realtime-openai`) and either use `_ =` or propagate the value, matching this task's pattern.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/swift-realtime-openai/Sources/WebRTC/WebRTCConnector.swift
git commit -m "feat(realtime-connector): propagate captured call ID through connect(using:)"
```

---

### Task 3: Propagate `providerCallId` through `Conversation.connect(using:)` / `connect(ephemeralKey:)`

**Files:**
- Modify: `apps/apple/Packages/swift-realtime-openai/Sources/UI/Conversation.swift:90-103`

- [ ] **Step 1: Change both `connect` overloads to return the captured `providerCallId`**

Replace the existing pair of functions:

```swift
public func connect(using request: URLRequest) async throws {
    await AVAudioApplication.requestRecordPermission()

    try await client.connect(using: request)
}

public func connect(ephemeralKey: String, model: Model = .gptRealtime) async throws {
    do {
        try await connect(using: .webRTCConnectionRequest(ephemeralKey: ephemeralKey, model: model))
    } catch let error as WebRTCConnector.WebRTCError {
        guard case .invalidEphemeralKey = error else { throw error }
        throw ConversationError.invalidEphemeralKey
    }
}
```

with:

```swift
/// Connects the underlying WebRTC peer and returns the OpenAI-assigned
/// Realtime call ID captured from the `Location` header of the call-creation
/// response (`nil` if it was missing/malformed — see `WebRTCConnector`).
@discardableResult
public func connect(using request: URLRequest) async throws -> String? {
    await AVAudioApplication.requestRecordPermission()

    return try await client.connect(using: request)
}

/// Convenience overload building the standard OpenAI Realtime WebRTC
/// connection request from an ephemeral key. Returns the same captured
/// provider call ID as `connect(using:)`.
@discardableResult
public func connect(ephemeralKey: String, model: Model = .gptRealtime) async throws -> String? {
    do {
        return try await connect(using: .webRTCConnectionRequest(ephemeralKey: ephemeralKey, model: model))
    } catch let error as WebRTCConnector.WebRTCError {
        guard case .invalidEphemeralKey = error else { throw error }
        throw ConversationError.invalidEphemeralKey
    }
}
```

- [ ] **Step 2: Verify the `UI` and umbrella `RealtimeAPI` targets still build**

Run: `swift build --package-path apps/apple/Packages/swift-realtime-openai`

Expected: `Build complete!`. This also exercises `RealtimeAPI` (the umbrella target that `@_exported import`s `UI`), and the `UITests` test target, which depends on `UI` — if `ConversationEventHandlingTests.swift` calls `connect(...)` anywhere, this build step (not `swift test`, just `build`) will still catch a signature mismatch since test targets are built as part of `swift build`'s dependency graph when you pass `--build-tests`, but plain `swift build` does NOT build test targets. Run the test build explicitly too:

Run: `swift test --package-path apps/apple/Packages/swift-realtime-openai --skip-build 2>&1 | true; swift build --package-path apps/apple/Packages/swift-realtime-openai --build-tests`

Expected: `Build complete!` with no errors referencing `ConversationEventHandlingTests.swift`. (This plan does not add or edit tests — this step exists purely to confirm the existing `UITests` target still compiles against the new signatures.)

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/swift-realtime-openai/Sources/UI/Conversation.swift
git commit -m "feat(realtime-connector): propagate captured call ID through Conversation.connect"
```

---

### Task 4: Expose `providerCallId` on `RealtimeAPIAdapter`

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift:34-53` (stored property + accessor)
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift:134-197` (`connect`)
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift:233-240` (`teardownActiveConversation`)

- [ ] **Step 1: Add the lock-guarded stored property and its public read-only accessor**

In the property-declaration block near the top of the class (right after the existing `toolCallContinuation` declaration at line 44), add:

```swift
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?

    // The OpenAI-assigned Realtime call ID (the `call_id` from the `Location`
    // header returned by `POST /v1/realtime/calls`), captured on a successful
    // `connect()`. `nil` before the first successful connect, after every
    // `disconnect()`/`teardownActiveConversation()`, or if the provider's
    // response was missing/malformed the `Location` header (see
    // `WebRTCConnector.fetchRemoteSDP` for that capture-failure case). A
    // later plan (voice-session-flow-wiring) reads this immediately after
    // `connect(...)` returns successfully and registers it with the Worker;
    // that plan must treat `nil` here as equivalent to a registration
    // failure (close the connection, show a retryable error) — this plan
    // does not implement that closing behavior.
    private var _providerCallId: String?
```

Then add the public accessor, next to the other lock-guarded read-only accessors — put it right before `public init() {}`:

```swift
    /// See the `_providerCallId` doc comment above for the full contract.
    public var providerCallId: String? {
        lock.withLock { _providerCallId }
    }

    public init() {}
```

- [ ] **Step 2: Capture the returned value and log its presence/absence inside `connect(...)`**

Find this line inside `connect(ephemeralKey:bookContext:language:)`:

```swift
        lock.withLock { self.conversation = convo }
        try await convo.connect(ephemeralKey: ephemeralKey)
```

Replace it with:

```swift
        lock.withLock { self.conversation = convo }
        let capturedProviderCallId = try await convo.connect(ephemeralKey: ephemeralKey)
        lock.withLock { self._providerCallId = capturedProviderCallId }
        // Never log the raw call ID value (spec: "Do not record ... OpenAI
        // call IDs in general logs") — presence/absence only.
        if capturedProviderCallId == nil {
            Log.event("voice.adapter.provider_call_id.missing", level: .warning)
        } else {
            Log.event("voice.adapter.provider_call_id.captured", level: .info)
        }
```

- [ ] **Step 3: Clear `_providerCallId` on every teardown**

Find `teardownActiveConversation()`:

```swift
    internal func teardownActiveConversation() async {
        pump.cancel()
        let convo: SDKConversation? = lock.withLock { self.conversation }
        if let convo {
            await MainActor.run { convo.disconnect() }
        }
        lock.withLock { self.conversation = nil }
    }
```

Replace the final line with a combined clear of both fields in one lock acquisition:

```swift
    internal func teardownActiveConversation() async {
        pump.cancel()
        let convo: SDKConversation? = lock.withLock { self.conversation }
        if let convo {
            await MainActor.run { convo.disconnect() }
        }
        lock.withLock {
            self.conversation = nil
            self._providerCallId = nil
        }
    }
```

This runs at the top of every `connect()` (single-peer invariant teardown) and inside `disconnect()`, so `providerCallId` never leaks a stale value from a prior connect attempt or a prior session into a new one.

- [ ] **Step 4: Verify `RishiVoice` builds and its existing test suite still passes unmodified**

Run: `swift build --package-path apps/apple/Packages/RishiVoice`

Expected: `Build complete!` with no errors.

Run: `swift test --package-path apps/apple/Packages/RishiVoice`

Expected: existing tests pass (no NEW tests were added by this plan — this run is a regression check that `FakeRealtimeClient`, `RealtimeAPIAdapterSmokeTests`, `RealtimeAPIAdapterConnectWaitTests`, `RealtimeAPIAdapterTeardownTests`, etc. still compile and pass against the unchanged `RealtimeClientAPI` protocol). This is expected to take a few minutes; if any test fails, check first whether it depends on `RealtimeAPIAdapter.connect`'s internal call sequence rather than its public protocol surface — nothing in this plan should change observable behavior for any existing test.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift
git commit -m "feat(voice-adapter): expose providerCallId captured from OpenAI call creation"
```

---

### Task 5: Full-package verification gate

**Files:** none (verification only)

- [ ] **Step 1: Build every affected package from a clean derived-data-free state**

Run:

```bash
swift build --package-path apps/apple/Packages/swift-realtime-openai --build-tests
swift build --package-path apps/apple/Packages/RishiVoice --build-tests
```

Expected: both report `Build complete!` with zero errors and zero new warnings (in particular, zero "result of call is unused" warnings — every new non-`Void` return in this plan is either consumed or explicitly discarded with `_ =`).

- [ ] **Step 2: Run both packages' existing test suites**

```bash
swift test --package-path apps/apple/Packages/swift-realtime-openai
swift test --package-path apps/apple/Packages/RishiVoice
```

Expected: all existing tests pass. No test file is created or modified by this plan.

- [ ] **Step 3: Confirm no other call sites were missed**

```bash
rg -n '\.connect\(using:|\.connect\(ephemeralKey:' apps/apple/Packages/swift-realtime-openai apps/apple/Packages/RishiVoice apps/apple/rishi 2>/dev/null
```

Expected: every `Conversation`/`WebRTCConnector`-level call site (not `RealtimeClientAPI`-protocol call sites like `fake.connect(...)` or `client.connect(...)` in `RealtimeVoiceSession.swift`/`ReconnectController.swift`, which are unaffected) is one this plan already updated. If `rg` surfaces an app-target (`apps/apple/rishi/`) call site directly against `Conversation` or `WebRTCConnector` (bypassing `RealtimeAPIAdapter`), typecheck that file too:

```bash
xcrun --sdk iphonesimulator swiftc -typecheck <that file>
```

- [ ] **Step 4: Note for the MAIN orchestrator (not a subagent), per `apps/apple/CLAUDE.md`**

This plan's package-level `swift build`/`swift test` gates above are sufficient for the subagent doing the implementation. The end-of-phase full `xcodebuild` integration check (confirming the app target itself, not just the packages, links cleanly) is the MAIN orchestrator's job once all 16 plans in this series have landed — do not run `xcodebuild rishi` from a subagent in this plan (600s stream-watchdog stall risk per CLAUDE.md).

---

## Self-review against the two source specs

- **no-card-credit-trial-design.md, Voice flow step 3** ("The OpenAI WebRTC call response includes the provider call ID in its `Location` header. The vendored Swift connector must retain this value, expose it to Rishi...") — covered: Tasks 1-2 retain it inside the vendored connector; Task 4 exposes it to Rishi (`RealtimeAPIAdapter.providerCallId`).
- **no-card-credit-trial-design.md, Voice flow step 3** ("...and immediately register it with the authenticated backend using the Rishi session ID and its one-time nonce") — explicitly OUT of scope for this plan (belongs to voice-session-flow-wiring); see "Exports for downstream plans" below.
- **no-card-credit-trial-design.md, Voice flow step 7** / **pricing-trial-launch-prerequisites-design.md, Voice Chat flow step 5** ("If the app fails to register the OpenAI call ID promptly, it must close..." / "Missing/late registration fails closed...") — this plan documents the missing-`Location`-header case as `nil` + a warning log (Task 1 Step 1, Task 4 Step 2) but does NOT implement closing the connection — that's the later plan's job per the task's explicit scope boundary (item 4).
- **pricing-trial-launch-prerequisites-design.md, Telemetry section** ("Do not record ... OpenAI call IDs in general logs") — covered: every log statement added logs presence/absence only, never the value (Task 1 Step 1 comment, Task 4 Step 2 code + comment).
- **pricing-trial-launch-prerequisites-design.md, Voice Chat flow step 4** ("The vendored Swift Realtime connector captures the OpenAI `call_id` from the `Location` header...") — covered by Tasks 1-2.
- Placeholder scan: no "TBD"/"handle appropriately"/"similar to Task N" language anywhere above; every step shows complete before/after code.
- Type consistency: `providerCallId: String?` is the exact name and type used from `RemoteSDPResult` (Task 1) through `performHandshake`/`connect(using:)` (Task 2), `Conversation.connect` (Task 3), and `RealtimeAPIAdapter.providerCallId` (Task 4) — no renaming anywhere in the chain.

---

## Exports for downstream plans

The **voice-session-flow-wiring** plan (and any other later plan needing the provider call ID) must use:

- **Read path:** `RealtimeAPIAdapter.providerCallId` — `public var providerCallId: String? { get }`, lock-guarded, on the concrete `RealtimeAPIAdapter` class (`apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift`). It is **not** part of the `RealtimeClientAPI` protocol — code that only holds `any RealtimeClientAPI` (e.g. `RealtimeVoiceSession`, `ReconnectController`, `FakeRealtimeClient`-based tests) cannot see it without either downcasting to `RealtimeAPIAdapter` or the later plan widening the protocol/injecting the adapter concretely. Decide that widening in the voice-session-flow-wiring plan, not here.
- **When to read it:** only after `RealtimeAPIAdapter.connect(ephemeralKey:bookContext:language:)` returns successfully (i.e., after `RealtimeVoiceSession.start()`'s `try await client.connect(...)` call succeeds and the session reaches `.live`). Reading it before that point, or after `disconnect()`/a failed `connect()`, returns `nil` by construction (Task 4 Step 3's teardown-clears-it behavior).
- **Missing-header failure case the later plan must handle:** `providerCallId == nil` immediately after a successful `connect()` return. This plan intentionally raises no error and does not close the connection for this case (see task scope boundary) — the later plan must treat it exactly like a registration failure per the no-card-credit-trial-design spec's Voice flow step 7 ("must close if registration fails"): close the just-opened voice connection and show a retryable error.
- **Reconnect gotcha the later plan must account for (not implemented here):** `ReconnectController.handleTransientDisconnect()` calls `client.connect(ephemeralKey:...)` again on every reconnect attempt. Each such call opens a brand-new OpenAI Realtime call with a brand-new `call_id`, and `RealtimeAPIAdapter.providerCallId` is overwritten (via `teardownActiveConversation()` clearing it, then the new `connect()` capturing the fresh value) on every reconnect, not just the first connect. The no-card-credit-trial-design spec's ledger currently only describes accepting a call ID "once for its active session" — the later plan needs to decide (and this plan deliberately does not decide) whether a reconnect's new call ID must be re-registered with the Worker, and if so, how the adapter surfaces "the call ID changed" as a distinct signal from "the call ID was captured for the first time." A `didSet`-style change notification or an `AsyncStream<String?>` are two options to evaluate then; this plan only guarantees the property always reflects the *current* connection's call ID (or `nil`).
