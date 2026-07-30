# Apple Voice Chat: On-Demand Current-Page Context

> **Status:** Adversarial review loop complete — **PASS** (5 rounds, 0 open Critical/High issues)

## Goal

Reduce Apple voice-chat startup payload and prevent stale reading context by removing visible-page text from initial realtime instructions and exposing the latest visible page through an on-demand `currentPageContext` tool.

## Scope

This change is limited to `apps/apple`. It covers the Apple reader voice entry points, the RishiVoice realtime adapter/session, and the local tool responder. Existing `bookContext` retrieval remains responsible for passages outside the visible page. The worker and shared prompt packages are out of scope for this change.

## Current problem

- EPUB `ReaderViewModel.voiceContext()` deliberately returns `pageText: nil` because extraction is asynchronous.
- PDF supplies page text only when the current page has selectable text and extraction is ready.
- The initial trial session is server-minted, so Apple currently avoids a client `session.update` before audio starts.
- The current-page snapshot is captured at voice launch and can become stale after navigation.

## Design

### Startup session

The initial `BookContextSnapshot` sent to the worker contains book identity and outline metadata, but no `pageText` or `activeParagraphText`. `RealtimeSessionConfigBuilder.makeInstructions` likewise contains no page body. This reduces the first request's input tokens and avoids claiming that a stale snapshot is current.

### Current-page tool

Apple registers a zero-argument function named `currentPageContext`. Its description tells the model to call it when the user asks about text or details on the page currently visible in the reader. The tool response is the exact Codable shape `{ "availability": "available"|"no_text"|"unavailable", "page": Int?, "pageText": String?, "activeParagraphText": String? }`. `no_text` is used for image-only or textless pages; `unavailable` is used for provider/read failures. The responder returns exactly one result for each recognized call.

The existing `BookContextResponder` is generalized into a single composite responder (or equivalent dispatcher) that consumes the shared tool stream once and routes `bookContext` to book search and `currentPageContext` to the live page provider. Unknown calls remain ignored. This avoids two consumers racing on the same stream.

The existing `bookContext(queryText)` tool is unchanged and remains the path for content outside the current page.

### Session update and latency

After the data channel is connected, but before microphone capture is enabled, `RealtimeAPIAdapter` sends one local `session.update` containing the Apple instructions and both tool definitions. The update replaces the server-minted tool/instruction set for the client session and is awaited only for configuration readiness. It does not delay WebRTC negotiation, entitlement checks, or peer prewarming.

The adapter subscribes to `sessionUpdates` before sending the update and waits for a post-send snapshot whose tool names and instruction fingerprint match the requested patch. The vendored SDK stream exposes only `RealtimeSession`, not the server event ID, so readiness is proven by a changed effective fingerprint rather than event-ID correlation. The adapter must first snapshot the pre-update fingerprint and must not accept that same snapshot as acknowledgement. Rejection or timeout is surfaced as a connection failure; microphone capture is not enabled before successful acknowledgement.

The initial update is a patch over the server-owned effective session: it changes only `instructions`, `tools`, and `toolChoice`. It does not send `audio` or `voice`, because Realtime `session.update` cannot change voice and the server-minted audio/VAD configuration is already valid. Reconnects may continue to build the complete local session because they create a new peer/session configuration.

Reconnects use the same local configuration path. The local session configuration must not include page text; only the `currentPageContext` tool can retrieve it.

### Live reader state

The reader passes a reader-independent, `Sendable` live provider alongside the initial context snapshot. The provider has the shape `@MainActor @Sendable () async throws -> CurrentPageContextResult`, where `CurrentPageContextResult` is owned by RishiVoice and contains only the Codable fields above. EPUB implementations await the existing asynchronous locator/paragraph extraction; PDF implementations may use the existing fast extraction path. The app target adapts `ReaderVoiceContext` and never makes RishiVoice import RishiReader.

The provider is weakly tied to the reader owner or backed by an actor/lock-owned snapshot so it cannot retain a dismissed reader indefinitely. After deallocation or teardown it returns `.unavailable`. The responder calls this provider at tool execution time, so page turns after voice startup are reflected without rebuilding the realtime session or sending page text in a session update.

The provider is installed for every compiled reader voice entry point: `ReaderScreen` toolbar and selection/quote actions, `PDFReaderScreen`, `ToolBar`, and the `ReaderDestination` audio overlay. The implementation audit must follow the current `ReaderDestinationView` routing and update each compiled call site; it must not assume `PDFReaderScreen` is the only PDF path. If the provider is unavailable during teardown, the tool returns the unavailable result rather than crashing or returning an old page.

`VoiceSessionPresenter` owns a single `metadataOnly(_:)` helper that sets `pageText` and `activeParagraphText` to `nil`. It calls this helper immediately before every `RealtimeVoiceSession.start`/retry call and before `session.updateReaderContext` on parked resume. This is the enforcement boundary for the no-page-body startup invariant; no session/fetcher path receives page body fields outside the tool provider.

`ReaderSessionIdentity` is a small `Hashable, Sendable` value wrapping a UUID. `ReaderVoiceEntry` creates one stable identity for its reader lifetime and passes it through `ReaderVoicePresenter.presentVoice`, `VoiceSessionPresenter.start`, and `RealtimeVoiceSession`. Parked sessions resume only when book ID and this identity match. Otherwise the presenter ends the parked session and creates a new one. Provider replacement is not performed on an existing responder.

The current production route in `ReaderDestinationView` is the unified `ReaderDestination`/`ReaderViewModel` path for both `.epub` and `.pdf`; its provider must use the unified view model's async visible-text extraction. The separately compiled `PDFReaderScreen` and `ToolBar` call sites are updated to the same provider contract where they are used by tests/previews or alternate hosts. This feature does not change route selection.

### Error behavior

- Missing page text: return a stable user-safe result indicating that the page has no extractable text; do not call book search.
- Provider/read failure: return a stable user-safe unavailable result and log the failure locally.
- Unknown tool calls remain ignored by the existing responder path.
- Ending/reconnecting a voice session cancels the current-page responder with the existing tool responder lifecycle.

## Data flow

```text
ReaderViewModel.voiceContext() ──initial metadata──> VoiceSessionPresenter
        │                                             │
        └──live provider─────────────────────────────> CurrentPageContextResponder
                                                      │
model calls currentPageContext ───────────────────────┘
                                                      │
                                      latest reader text returned
```

## Tests

- `RealtimeSessionConfigBuilderTests`: initial instructions exclude visible page text and active paragraph text; tools include `currentPageContext` plus `bookContext`.
- `RealtimeAPIAdapterSessionConfigurationTests`: the adapter sends/accepts a post-connect local session patch using a changed configuration fingerprint, preserves server-owned audio/VAD/voice settings, and does not include page text in it.
- `CurrentPageContextResponderTests`: returns the provider's latest page, handles no text, provider failure, malformed/irrelevant calls, and cancellation.
- `RealtimeVoiceSessionBookContextTests` or a focused composite-responder test: both tools share one stream, the live provider reaches the current-page route, and the responder is cancelled on teardown.
- Session ordering test: data-channel open → changed-fingerprint `session.update` accepted → microphone enabled.
- Reader voice presenter tests: every compiled reader entry point supplies a live provider while presenter sanitization omits page text on initial/retry/reconnect paths; parked-session identity mismatch starts a fresh session.

## Explicit non-goals

- No worker/shared prompt changes.
- No change to semantic book search or indexing.
- No page-text caching or token/reference scheme.
- No automatic tool call on every page turn; page text is fetched only when the model asks.

## Adversarial research review

Each round: review → log findings → update the artifact → re-review.

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | An Apple-only tool is not present in the initial worker-minted session; simply adding a local definition would leave the model unaware of it on the first connection. | Require a post-connect `session.update` before microphone capture, and test the initial-session path explicitly. |
| 2 | High | A launch-time snapshot would remain stale after the reader changes pages. | Pass a live main-actor provider to the responder and call it at tool execution time. |
| 3 | Medium | EPUB and PDF can have no extractable text, so the model needs a deterministic response rather than an empty tool result. | Define an explicit unavailable/image-only response and test both formats' no-text behavior. |

**Round 1 result:** High findings resolved in the design; re-review required.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Replacing the server session configuration could accidentally drop server VAD/audio or the existing `bookContext` tool. | The local configuration must include the complete existing audio/VAD configuration and both tools; add a session snapshot assertion for tool count and audio settings. |
| 2 | High | A provider closure could outlive the reader and touch deallocated UI state. | Make the provider weakly capture the reader/view model where applicable; teardown must cancel the responder, and the responder must return unavailable after provider failure. |
| 3 | Medium | A post-connect update could still delay the first user turn if microphone capture is enabled first. | Make `RealtimeVoiceSession` await configuration before `setMicCaptureEnabled(true)` and add ordering coverage. |

**Round 2 result:** High findings resolved in the design; re-review required.

### Round 3 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The test list did not explicitly cover all Apple reader voice call sites. | Include EPUB, PDF, ReaderScreen, PDFReaderScreen, ToolBar, ReaderDestination overlay, and selection/quote paths in the implementation call-site audit. |

**Round 3 result:** Re-review required — an independent reviewer found three Critical and five High issues: the responder ignored the new tool, update readiness was not correlated, and provider isolation/lifecycle plus metadata-only enforcement were underspecified.

### Round 4 — Resolution and re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | A second responder would race the existing responder, while the existing responder ignores unknown tool names. | Replace it with one composite dispatcher that routes both recognized tools and returns one result per call. |
| 2 | Critical | A buffered `session.created` snapshot could be mistaken for acknowledgement of the new update. | Require a changed effective configuration fingerprint after the send; the vendored SDK does not expose event IDs through its session stream. |
| 3 | Critical | Local reconnect configuration could still embed page text or drop audio/VAD/server tools. | Make local configuration structurally metadata-only and assert full audio/VAD + two-tool parity in tests. |
| 4 | High | EPUB extraction cannot satisfy a synchronous provider. | Define an async provider owned by a reader-independent RishiVoice result type. |
| 5 | High | A parked responder could retain a prior reader/book/provider. | Resume only for matching book/provider identity; otherwise end and recreate. |
| 6 | High | MainActor/sendability and reader lifetime were ambiguous. | Specify `@MainActor @Sendable` async provider isolation and weak/actor-owned lifetime behavior. |

**Round 4 result:** Re-review required — the independent reviewer found five High gaps: SDK event IDs are not exposed, full audio updates could attempt to change voice, sanitization and parked identity lacked exact seams, and PDF routing was overstated.

### Round 5 — Resolution and re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The SDK stream does not expose `session.updated` event IDs. | Use pre-update/effective configuration fingerprints and require a changed post-send snapshot; do not claim event-ID correlation. |
| 2 | High | Sending a full audio block in `session.update` could violate the immutable voice rule. | Send an instructions/tools/toolChoice-only patch for the initial connection; preserve server-owned audio/VAD/voice. |
| 3 | High | Page-body removal was not assigned to one enforceable boundary. | Add `VoiceSessionPresenter.metadataOnly(_:)` and use it before initial/retry calls and parked `updateReaderContext`; assert nil fields in every session-path test. |
| 4 | High | Closure identity cannot be compared for parked-session safety. | Add concrete `ReaderSessionIdentity: Hashable & Sendable`, generate it in `ReaderVoiceEntry`, and thread it through presenter/session parked matching. |
| 5 | High | The spec claimed both PDF production routes without resolving current routing. | Specify the unified `ReaderDestination` route as production for both formats, use its async provider, and update separately compiled `PDFReaderScreen`/`ToolBar` call sites without changing routing. |

**Round 5 result:** PASS — 0 open Critical/High issues.
