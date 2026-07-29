# Rishi Data Use Consent Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Rishi’s Apple app and worker obtain one explicit, clearly scoped consent before sending remote user data to Rishi cloud or AI providers, and make the public privacy page accurately disclose those transfers.

**Architecture:** Add a versioned, account-scoped data-use consent store in the Apple app and a reusable consent-aware request contract. Remote content/data requests carry `X-Rishi-Data-Use-Consent: 2026-07-29`; the worker rejects missing or unsupported values before parsing, accounting, caching, ledger mutation, sync, or provider calls. The Apple app’s current ledger-backed voice-session flow is the only production voice path; the removed legacy client-secret path remains unavailable. Authentication-only and billing/entitlement requests remain outside the content-use gate.

**Tech Stack:** Swift 6, SwiftUI, Foundation URLSession, Cloudflare Workers/Hono, Bun/Vitest, Next.js/React.

---

## Requirements and acceptance criteria

- A signed-in user sees one in-app data-use disclosure before the first remote sync or AI action.
- The disclosure names the relevant provider(s), data categories, purposes, public privacy policy, and affirmative/decline actions.
- Consent is stored under `dataUseConsent.<userId>` with version and timestamp; it is never device-global and is cleared from memory on sign-out.
- New content/data and AI requests are impossible without current consent. Revocation blocks new requests without deleting ordinary synced data.
- Every worker provider route rejects missing/unsupported consent before side effects and accepts the current header.
- The privacy page no longer contradicts actual AI-provider sharing, Sentry/operational metadata, transcript persistence, or R2 narration caching.
- Existing authentication and billing/entitlement flows continue without the content-use header; sync/content routes require it.

## File map and ownership

Apple app:

- Create consent model/store/UI files under `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/AIDataConsent/` and add them to the existing Xcode target/package manifests if required.
- Modify `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerEndpoint.swift` and `WorkerClient.swift` for marker-based header injection in normal and streaming requests.
- Modify remote content/data endpoint declarations under `Modules/RishiChat`, `Modules/RishiAudio`, `Modules/RishiCore`, `Modules/RishiSync`, and voice session API files to opt into the marker.
- Modify `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/ControlWebSocketClient.swift`, `RealtimeVoiceSession.swift`, `VoiceSessionPresenter.swift`, and onboarding/Settings surfaces for consent ordering, revocation, and account lifecycle.
- Modify `apps/apple/rishi/rishi/AppDependencies+Billing.swift` or the app dependency graph for sign-out cleanup and consent-store injection.
- Add focused tests under the existing `rishiTests` package targets for the consent store, request builders, endpoint markers, and voice/chat/TTS gates.

Worker:

- Create `workers/worker/src/middleware/ai-data-consent.ts` and its test.
- Modify `workers/worker/src/index.ts`, `routes/chat.ts`, and `routes/voice-sessions.ts` to apply the guard before all provider-facing side effects.
- Modify the ElevenLabs and transcription handlers in `index.ts` as needed; do not add raw SQL.
- Add/update route tests under `workers/worker/src/routes/` and focused provider tests using Bun/Vitest.

Web:

- Modify `apps/web/src/app/privacy/page.tsx` sections on collection, use, retention/deletion, security, and third parties.
- Create a small exported policy-content model or a content-level test under the existing web test convention so required provider/data/purpose disclosures are asserted.

## Implementation order

1. Worker consent middleware tests and implementation.
2. Apple consent store/model tests and implementation.
3. Apple request-header contract and endpoint markers.
4. Apple feature gates and voice/onboarding/account lifecycle.
5. Web privacy-policy corrections and tests.
6. Independent implementation review, focused tests, iOS build, and worker/web verification.

### Task 1: Add the worker data-use consent boundary

**Files:**

- Create: `workers/worker/src/middleware/ai-data-consent.ts`
- Test: `workers/worker/src/middleware/ai-data-consent.test.ts`
- Modify: `workers/worker/src/index.ts`
- Modify: `workers/worker/src/routes/chat.ts`
- Modify: `workers/worker/src/routes/voice-sessions.ts`

- [ ] **Step 1: Write failing middleware tests.** Assert that `requireAIDataConsent` returns HTTP 428 and `{ error: "AI_DATA_CONSENT_REQUIRED" }` for a missing header and an unsupported version, and calls the downstream handler exactly once for `2026-07-29`.
- [ ] **Step 2: Run the focused test and confirm the expected failure.** Run `cd workers/worker && bun test src/middleware/ai-data-consent.test.ts`; expected failure is the missing middleware/export, not a test-runner error.
- [ ] **Step 3: Implement the minimal middleware.** Export `AI_DATA_CONSENT_HEADER`, `AI_DATA_CONSENT_VERSION`, and `requireAIDataConsent`; inspect only the header, return the stable 428 JSON error on mismatch, and otherwise call `next()`.
- [ ] **Step 4: Add failing route-order tests.** Extend route tests to assert no OpenAI/Deepgram call, usage increment, cache lookup, allowance refresh, ledger `createVoiceSession`, or sync mutation occurs when consent is missing. Cover `/api/chat`, `/api/audio/speech`, `/api/audio/transcribe`, `/api/voice-sessions`, `/api/text/completions`, `/api/embed`, and sync/conversation/message routes that transmit user content.
- [ ] **Step 5: Apply the guard before side effects.** Put it after `requireAuth` and before body parsing or any handler work on each route. Add it to `/api/voice-sessions/:id/control` before session lookup. Keep `/api/realtime/client_secrets` removed and add a test that it is not registered.
- [ ] **Step 6: Run worker tests.** Run `cd workers/worker && bun test src/middleware/ai-data-consent.test.ts src/routes/chat.test.ts src/routes/voice-sessions.test.ts src/audio-transcribe.test.ts`; expected result is green.

### Task 2: Add the Apple account-scoped consent store

**Files:**

- Create: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/AIDataConsent/AIDataConsent.swift`
- Create: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/AIDataConsent/AIDataConsentStore.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiSettings/RishiSettingsTests/AIDataConsentTests.swift`

- [ ] **Step 1: Write failing store tests.** Cover absent user/no grant, granting user A, loading user A’s version/timestamp, user B not inheriting user A’s grant, unsupported version invalidation, revocation, and sign-out memory reset.
- [ ] **Step 2: Run the focused Apple test and confirm it fails for the intended missing behavior.** Use the repository’s existing Xcode test command for the `rishiTests` target and the new test case; correct target/path errors before proceeding.
- [ ] **Step 3: Implement the pure consent model and protocol.** Use the exact version `2026-07-29`, a `ConsentRecord` containing version and timestamp, and an async/in-memory-friendly store API with explicit current-user activation plus `record(for:)`, `grant(for:)`, `revoke(for:)`, `clearCurrentUser()`, and `isCurrent(for:)`.
- [ ] **Step 4: Implement the UserDefaults store.** Use the exact key `dataUseConsent.<userId>`, never use a global key, ignore malformed records, and keep the current user’s record out of SwiftUI view-local state so account switching cannot inherit it.
- [ ] **Step 5: Run the focused test again and confirm green.** Keep the store free of networking and provider logic.

### Task 3: Add the shared Apple request contract

**Files:**

- Modify: `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerEndpoint.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerClient.swift`
- Modify: AI endpoint declarations in `Modules/RishiChat`, `Modules/RishiAudio`, `Modules/RishiCore`, and `Modules/RishiVoice`
- Test: existing endpoint codable/request-builder tests plus a new `AIDataConsentRequestTests.swift` in the relevant package target

- [ ] **Step 1: Write failing request-builder tests.** Assert marked normal HTTP endpoints and marked streaming endpoints receive `X-Rishi-AI-Data-Consent: 2026-07-29` only when the injected consent provider reports a current grant; non-AI endpoints never receive it.
- [ ] **Step 2: Run the focused tests and confirm failure.** The expected failure is absent header injection/marker behavior.
- [ ] **Step 3: Implement one shared constant/provider seam.** Add a sendable consent-header provider to `WorkerClient`, defaulting to no header in tests and previews. Add default-false marker requirements to normal and streaming endpoint protocols; mark sync/content plus chat, text completion, embeddings, TTS, ElevenLabs, transcription, and voice-session creation endpoints true.
- [ ] **Step 4: Apply the same helper to both `buildRequest` and `buildStreamingRequest`.** Do not path-match strings; the endpoint declaration owns whether it carries AI data.
- [ ] **Step 5: Add voice WebSocket header injection.** Pass the same current header provider into `ControlWebSocketClient` and attach the header to its worker upgrade request. The direct OpenAI WebRTC connection is only created after the consent-gated worker voice-session mint succeeds.
- [ ] **Step 6: Run the focused Apple tests and confirm green.** Verify ordinary auth, sync, billing, and upload endpoint request assertions remain unchanged.

### Task 4: Gate Apple remote data features and lifecycle

**Files:**

- Modify: `apps/apple/rishi/rishi/RootView.swift` and app dependency construction for consent injection
- Modify: `apps/apple/rishi/rishi/Modules/RishiChat/RishiChat/Service/RishiChat_ChatService.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/TTS/TTSStreamer.swift` or its caller seam
- Modify: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/RealtimeVoiceSession.swift`
- Modify: `apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift`
- Modify: `apps/apple/rishi/rishi/Onboarding/OnboardingHost.swift` and `Modules/RishiOnboarding/.../OnboardingFlowView.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/SettingsScreen.swift` and add an AI-data consent section/view
- Modify: `apps/apple/rishi/rishi/AppDependencies+Billing.swift` for sign-out clearing
- Tests: existing chat/audio/voice/onboarding/settings tests plus focused consent-gate tests

- [ ] **Step 1: Write failing gate tests.** Assert that the single data-use entry point gates sync and each AI entry point before persisting or sending its payload; denial leaves local reading usable; current consent proceeds; revoked/version-stale consent blocks; microphone permission is not requested before data-use consent in onboarding and voice start.
- [ ] **Step 2: Run the focused tests and confirm failure.** Verify failures demonstrate missing gate behavior rather than broken test fixtures.
- [ ] **Step 3: Implement the disclosure UI.** Use one reusable screen/confirmation view with two clearly labeled sections—Rishi cloud sync and third-party AI providers—exact data/purpose text, a Privacy Policy link, “Allow data use,” and “Not now.” Make it accessible from Settings for review and revocation.
- [ ] **Step 4: Integrate the gate before side effects.** Sync must not upload/push content before consent. Chat must not persist/send a user turn before consent. TTS must not start read-ahead or stream paragraph text before consent. Voice must not call `micGate.request()`, create a worker session, or connect WebRTC before consent. Standalone transcription must use the same gate.
- [ ] **Step 5: Order onboarding and permission flows.** If onboarding offers microphone setup, show the AI-data consent first; only after affirmative consent may the microphone primer/system prompt appear. “Not now” completes onboarding without blocking reading.
- [ ] **Step 6: Wire account lifecycle and Settings revocation.** Load consent only after `CurrentUserBox` identifies the signed-in user, clear in-memory state on sign-out/account switch, revoke the current user’s persisted record from Settings, and ensure a different user’s grant is never visible.
- [ ] **Step 7: Remove the Apple legacy voice path.** Make the production construction always use the ledger-backed `VoiceSessionCoordinating` flow; remove the production `EphemeralKeyFetcher` selection and leave no Apple caller for `/api/realtime/client_secrets`.
- [ ] **Step 8: Run focused Apple voice/chat/audio/onboarding tests and confirm green.** Include the existing mic denial and session lifecycle suites.

### Task 5: Correct the public privacy policy

**Files:**

- Modify: `apps/web/src/app/privacy/page.tsx`
- Create/modify: the existing web test file or `apps/web/src/app/privacy/page.test.tsx`, following the package’s test convention

- [ ] **Step 1: Write a failing content test.** Assert the rendered policy contains OpenAI, ElevenLabs, Deepgram, chat prompts, book/page text, narration, microphone audio, transcripts, purposes, R2 narration caching, conversation synchronization, Sentry/operational metadata, and a consent/withdrawal statement.
- [ ] **Step 2: Run the focused web test and confirm failure.** Use the package’s existing Bun/Next test command and fix only test-environment setup issues.
- [ ] **Step 3: Replace contradictory sections.** Update collection/use/storage/retention/deletion/security/third-party sections instead of appending a disclaimer. State which provider receives which data, distinguish content from metadata, name provider-side policy uncertainty, and do not claim “no sharing,” “no usage data,” or unsupported retention/model-training guarantees.
- [ ] **Step 4: Run the focused web test and confirm green.** Render the route if the package supports it and verify the public Privacy Policy link used by the Apple app still resolves.

### Task 6: Verification and implementation review

- [ ] Run the full focused worker suite from `workers/worker` with Bun.
- [ ] Run the Apple focused StoreKit-independent tests, then the required iOS build/test command for the touched target.
- [ ] Run the web privacy test and package typecheck/lint command if available.
- [ ] Search every AI provider call and verify the Apple caller is consent-gated and the worker route is guarded before side effects.
- [ ] Inspect `git diff` without touching pre-existing build artifacts or unrelated worktree changes.
- [ ] Dispatch an independent implementation reviewer. Log findings, fix Critical/High findings, and re-review the updated diff until the final table has zero open Critical/High issues.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review.

### Round 1 — Plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Consent could be implemented only in UI while background/read-ahead paths still transmit content. | Task 4 explicitly gates chat persistence, TTS read-ahead, standalone transcription, and voice session creation before side effects. |
| 2 | High | Separate normal, streaming, and WebSocket networking paths could drift. | Task 3 requires one marker/provider contract across normal HTTP, streaming HTTP, and worker WebSocket requests. |
| 3 | High | Worker route checks could occur after accounting/ledger mutations. | Task 1 requires middleware ordering before parsing, usage, cache, allowance, ledger, and provider work, with side-effect tests. |
| 4 | High | Account A’s grant could leak to account B or a signed-out state. | Task 2 and Task 4 define per-user keys, no anonymous fallback, and sign-out memory clearing. |
| 5 | High | Privacy page could retain contradictory “no sharing/no usage data” claims. | Task 5 requires replacing the affected sections and content tests for the actual disclosures. |
| 6 | Medium | Legacy Apple voice flow could keep calling the removed worker endpoint. | Task 4 removes the production legacy selection and tests that no Apple caller remains. |

**Round 1 result:** Re-review required until the plan’s concrete file/API/test steps are checked against the current implementation.

### Round 2 — Re-review

The plan covers all provider-facing routes, all Apple request surfaces, background/read-ahead behavior, lifecycle isolation, contradictory policy content, legacy voice routing, and required verification. **PASS — 0 open Critical/High issues.**

## Explicitly out of scope

- App Store Connect price confirmation for Voice Annual `143.99`.
- Subscription product, billing, or entitlement changes.
- Database persistence of data-use consent.
- New provider integrations or unsupported provider-retention/model-training claims.
