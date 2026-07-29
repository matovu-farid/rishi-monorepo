# Apple Voice Chat: On-Demand Current-Page Context

> **Status:** Draft — awaiting user review after adversarial research review

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

Apple registers a zero-argument function named `currentPageContext`. Its description tells the model to call it when the user asks about text or details on the page currently visible in the reader. The tool response is a compact JSON object containing the latest page number, page text, and active paragraph when available. It returns an explicit unavailable/image-only result when extraction produces no text.

The existing `bookContext(queryText)` tool is unchanged and remains the path for content outside the current page.

### Session update and latency

After the data channel is connected, but before microphone capture is enabled, `RealtimeAPIAdapter` sends one local `session.update` containing the Apple instructions and both tool definitions. The update replaces the server-minted tool/instruction set for the client session and is awaited only for configuration readiness. It does not delay WebRTC negotiation, entitlement checks, or peer prewarming.

Reconnects use the same local configuration path. The local session configuration must not include page text; only the `currentPageContext` tool can retrieve it.

### Live reader state

The reader passes a main-actor context provider alongside the initial context snapshot. `ReaderVoiceEntry` maps the provider's latest `ReaderVoiceContext` into the tool response. The responder calls this provider at tool execution time, so page turns after voice startup are reflected without rebuilding the realtime session or sending page text in a session update.

The provider is installed for every reader voice entry point (EPUB, PDF, toolbar, selection/quote, and audio overlay). If the provider is unavailable during teardown, the tool returns the unavailable result rather than crashing or returning an old page.

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

- `RealtimeSessionConfigBuilderTests`: initial instructions exclude visible page text and tools include `currentPageContext` plus `bookContext`.
- `RealtimeAPIAdapterSessionConfigurationTests`: the adapter sends/accepts the post-connect local session configuration and does not include page text in it.
- `CurrentPageContextResponderTests`: returns the provider's latest page, handles no text, provider failure, malformed/irrelevant calls, and cancellation.
- `RealtimeVoiceSessionBookContextTests` or a focused session test: the live provider reaches the responder and is cancelled on teardown.
- Reader voice presenter tests: every reader entry point supplies a provider while the initial snapshot omits page text.

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

**Round 3 result:** PASS — 0 open Critical/High issues.

