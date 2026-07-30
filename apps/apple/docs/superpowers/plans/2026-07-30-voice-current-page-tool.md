# Apple Voice Current-Page Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove page body text from Apple voice-chat startup context and provide the latest visible page only through a live `currentPageContext` tool.

**Architecture:** Keep startup/session metadata limited to book identity, outline, language, audio, and server-owned VAD. The Worker mints the complete Realtime session, including `bookContext` and `currentPageContext` tool definitions and metadata-only instructions. Apple only connects through the SDK and answers the live page tool call; it does not send a post-connect `session.update`. The page tool uses an async, reader-independent provider backed by the current reader state. The abandoned local activation/VAD experiment is removed.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI `@MainActor`, vendored `swift-realtime-openai` WebRTC conversation, RishiVoice actors.

---

## Files and ownership

| Area | Files | Responsibility |
|---|---|---|
| RishiVoice value/protocol seam | `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/RealtimeClientAPI.swift`, new `CurrentPageContext.swift` | Sendable provider/result and SDK connection seam |
| Worker/shared voice contract | `workers/worker/src/realtime/client-secrets.ts`, `packages/shared/src/voice-chat/build-realtime-agent.ts` | Mint metadata-only instructions and both tool definitions |
| Vendored realtime SDK | `apps/apple/rishi/rishi/Modules/swift-realtime-openai/UI/...Conversation.swift` | Connect the already-configured server session without a client session update |
| Prompt/tools | `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/RealtimeSessionConfigBuilder.swift` | Metadata-only instructions and two tool definitions |
| Tool dispatch | `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/CompositeVoiceToolResponder.swift`, existing `BookContextResponder.swift` | Single stream consumer for both tools |
| Session lifecycle | `RealtimeAPIAdapter.swift`, `RealtimeVoiceSession.swift`, `VoiceSessionPresenter.swift` | Session patch/readiness ordering, provider and identity threading, metadata sanitization |
| App-reader bridge | `ReaderVoiceEntry.swift`, `ReaderVoicePresenter.swift`, `ReaderViewModel.swift`, `PDFReaderScreen.swift`, `ToolBar.swift`, `ReaderScreen.swift`, `ReaderDestination.swift` | Live async provider and all compiled voice call sites |
| Tests | Existing RishiVoice/RishiReader test targets plus new focused responder tests | Red-green verification of each boundary |

## Implementation order

1. Add pure result/provider types and failing prompt/tool tests.
2. Add the composite responder and failing dispatch tests.
3. Move all tool definitions into the Worker-minted session and add server-readiness tests.
4. Thread provider and `ReaderSessionIdentity` through session lifecycle and reader call sites.
5. Update existing assertions, run focused tests, then run the Apple build/test gates.

### Task 1: Define metadata-only context and tool contract

**Files:**
- Create: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/CurrentPageContext.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/RealtimeSessionConfigBuilder.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/Service/RealtimeSessionConfigBuilderTests.swift`

- [ ] **Step 1: Write failing tests.** Assert `makeInstructions(bookContext:)` contains book identity but not page text or active paragraph; assert tools contain exactly `bookContext` and `currentPageContext`; assert the current-page tool has no required arguments.
- [ ] **Step 2: Run the focused RishiVoice test target and verify the new assertions fail** because the builder currently embeds page text and exposes only one tool.
- [ ] **Step 3: Implement the minimal contract.** Add `ReaderSessionIdentity` (`Hashable`, `Sendable`), `CurrentPageContextResult` with exact `availability/page/pageText/activeParagraphText` Codable fields, and an async provider type. Make `makeInstructions` metadata-only and add the zero-argument tool definition. Keep `bookContext(queryText)` unchanged.
- [ ] **Step 4: Run the focused tests and verify they pass.** Update old tests that assert visible page text in instructions to assert its absence.

### Task 2: Replace the single-tool responder with composite dispatch

**Files:**
- Create: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/CompositeVoiceToolResponder.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/BookContextResponder.swift` only if shared decoding/result helpers are extracted
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/Service/CompositeVoiceToolResponderTests.swift`

- [ ] **Step 1: Write failing tests** for one shared stream containing `bookContext`, `currentPageContext`, and an unknown tool; assert one result per recognized call, live provider invocation at call time, explicit `no_text`/`unavailable` results, and cancellation behavior.
- [ ] **Step 2: Run the new test and verify it fails** because the current responder ignores `currentPageContext` and the session factory supports only `BookContextResponder`.
- [ ] **Step 3: Implement the composite responder.** Give it the existing book-search dependency plus the async current-page provider. Route `bookContext` through the existing search behavior and `currentPageContext` through the provider; send exactly one JSON payload per recognized call; log and ignore unknown tools.
- [ ] **Step 4: Run responder tests and verify they pass**, including the no-text and provider-error cases.

### Task 3: Mint the complete session server-side and remove custom activation/VAD

**Files:**
- Modify: `workers/worker/src/realtime/client-secrets.ts`
- Modify: `packages/shared/src/voice-chat/build-realtime-agent.ts`
- Modify: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/RealtimeAPIAdapter.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/RealtimeVoiceSession.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/Service/RealtimeAPIAdapterSessionConfigurationTests.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/Service/RealtimeVoiceSessionTests.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/Fakes/FakeRealtimeClient.swift`

- [ ] **Step 1: Write regression tests** for the Worker payload containing both tools, metadata-only instructions, and the required realtime session type.
- [ ] **Step 2: Add the shared `currentPageContext` tool contract and have the Worker mint it with the session.** Do not include page body or active paragraph text in the startup instructions.
- [ ] **Step 3: Remove the production activation recorder, energy/speech VAD monitors, PCM handoff, and activation-specific adapter path.** Live mic capture is enabled by the SDK-backed adapter after connection; turn detection remains OpenAI/server-owned.
- [ ] **Step 4: Remove Apple post-connect `Conversation.updateSession`; wait only for the server-minted configured session before enabling the microphone.
- [ ] **Step 5: Run shared/Worker and Apple static verification.**

### Task 4: Thread live reader provider and identity

**Files:**
- Modify: `apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift`
- Modify: `apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderVoicePresenter.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderViewModel.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/PDF/PDFReaderViewModel.swift` if its provider adapter needs a separate fast path
- Modify: compiled call sites in `ReaderScreen.swift`, `PDFReaderScreen.swift`, `ToolBar.swift`, and `ReaderDestination.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/UI/ReaderVoicePresenterTests.swift`
- Test: `apps/apple/rishi/rishiTests/Voice/ReaderVoiceEntryContextTests.swift`
- Test: `apps/apple/rishi/rishiTests/Voice/VoiceSessionPresenterContextTests.swift`
- Test: `apps/apple/rishi/rishiTests/Voice/VoiceSessionPresenterParkTests.swift`

- [ ] **Step 1: Write failing tests** asserting the initial snapshot has nil page body fields, the provider returns the latest EPUB/PDF visible context asynchronously, and parked reuse requires matching `ReaderSessionIdentity`.
- [ ] **Step 2: Run the focused tests and verify they fail** because the protocol has no provider/identity and EPUB `voiceContext()` returns nil page text without a provider.
- [ ] **Step 3: Add the reader-independent provider seam.** Update the reader presenter protocol to carry an async provider and identity. In `ReaderVoiceEntry`, generate one identity per reader lifetime, map the latest reader context into `CurrentPageContextResult`, and weakly/actor-safely handle reader teardown.
- [ ] **Step 4: Implement EPUB extraction through the existing async locator/paragraph path** and PDF extraction through the current-page text path. Keep the startup snapshot metadata-only.
- [ ] **Step 5: Add `VoiceSessionPresenter.metadataOnly(_:)`** and use it before initial start, retry, reconnect, and parked `updateReaderContext`; compare book ID plus identity before parked reuse.
- [ ] **Step 6: Update every compiled voice call site** to provide the live provider: unified `ReaderDestination` production route for EPUB/PDF, plus separately compiled `PDFReaderScreen`, `ToolBar`, `ReaderScreen`, and audio-overlay/selection actions.
- [ ] **Step 7: Add app-target bridge tests** for `ReaderVoiceEntry` provider construction, stable identity generation, metadata-only snapshots, unified `.epub`/`.pdf` `ReaderDestination` wiring, and separately compiled `PDFReaderScreen`/`ToolBar` call-site adapters. These tests live in the app target because package-level reader protocol fakes cannot observe app-layer mapping.
- [ ] **Step 8: Run reader/presenter tests and verify they pass.**

### Task 5: Verification and cleanup

**Files:** all files changed above.

- [ ] **Step 1: Run focused RishiVoice and RishiReader tests** covering prompt, responder, adapter ordering, session teardown, and reader provider behavior.
- [ ] **Step 2: Run the Apple build and relevant voice tests** using the repository-approved `xcodebuild` commands for `StoreTests`, `VoiceSessionPresenterSingleSessionTests`, and voice/reader suites as applicable.
- [ ] **Step 3: Inspect the diff** for accidental page text in startup requests, duplicate stream consumers, unbounded provider captures, and user worktree changes unrelated to this feature.
- [ ] **Step 4: Update the spec/plan status and record the final verification evidence.**

## Consumer / call-site audit

| Call site | Required change |
|---|---|
| `ReaderScreen.swift` toolbar and selection actions | Pass metadata snapshot, live provider, and stable identity |
| `PDFReaderScreen.swift` voice action | Pass the same provider contract |
| `ToolBar.swift` voice/quote actions | Pass the same provider contract |
| `ReaderDestination.swift` audio overlay | Pass the same provider after read-aloud handoff |
| `ReaderDestinationView.swift` | Preserve unified production routing; verify both `.epub` and `.pdf` use the provider |
| `VoiceSessionPresenter.swift` initial/retry/reconnect/parked paths | Sanitize metadata and compare identity |
| `RealtimeVoiceSession.swift` responder/session lifecycle | Patch before mic, composite stream consumer, teardown cancellation |

## Explicit out of scope

- Worker/shared prompt changes.
- Semantic search/indexing changes.
- Token/reference caching for page content.
- Automatic page-context calls on every page turn.
- Reader route selection changes.

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The plan could accidentally create two consumers of the same tool stream. | Task 2 requires one composite responder and Task 3 changes the session factory to create only that consumer. |
| 2 | High | The existing SDK session-update API serializes required audio/voice fields and cannot implement the requested patch. | Task 3 now adds a concrete vendored `SessionUpdatePatch`/`ClientEvent` wire type and tests that `audio`/`voice` keys are absent. |
| 3 | High | Async EPUB extraction was not represented in the implementation order. | Task 4 defines the async provider and tests it before wiring call sites. |
| 4 | High | Parked-session reuse could retain stale reader context. | Task 1 adds identity; Task 4 sanitizes all paths and requires book + identity match. |
| 5 | High | Reconnects use a direct client connect path and could lose or duplicate the responder if patching is owned by the session actor. | Task 3 makes the adapter patch every connect/reconnect and keeps one persistent composite responder in the session actor. |
| 6 | High | Package-level reader tests cannot verify app-layer provider mapping and production route wiring. | Task 4 adds app-target bridge tests for `ReaderVoiceEntry`, unified routing, and alternate compiled call sites. |

**Round 1 result:** Re-review required after plan update.

### Round 2 — Plan re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The plan needed explicit evidence that the initial snapshot, retries, and parked resume all omit page text. | Task 3 and Task 4 each require path-specific assertions, and Task 5 includes a diff audit for startup payloads. |
| 2 | Medium | The plan could leave the separate PDF screen call site unhandled. | Consumer audit names `PDFReaderScreen.swift` separately from the unified production route. |

**Round 2 result:** Re-review required — an independent reviewer found four High issues: the SDK patch API was not concrete, the fake/protocol seam was missing, reconnect responder ownership was underspecified, and app-layer bridge tests were absent.

### Round 3 — Resolution and re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Existing `Conversation.updateSession(withChanges:)` cannot emit a partial patch without audio/voice. | Add and test a vendored `SessionUpdatePatch` plus `ClientEvent.updateSessionPatch` wire model. |
| 2 | High | `RealtimeClientAPI`/`FakeRealtimeClient` lacked an update acknowledgement seam. | Add the exact async protocol method and deterministic fake recording/acknowledgement hook. |
| 3 | High | Reconnect calls `client.connect` directly, so session-owned patch/responder ordering was unclear. | Make `RealtimeAPIAdapter.connect` patch every connection and keep the composite responder persistent across reconnects. |
| 4 | High | Package tests cannot prove app-layer context mapping or route wiring. | Add app-target bridge tests and retain package tests for pure RishiVoice behavior. |

**Round 3 result:** PASS — 0 open Critical/High issues.
