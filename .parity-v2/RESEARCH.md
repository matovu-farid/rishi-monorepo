# RESEARCH.md — Parity v2 Research Report

**Research date:** 2026-06-04
**Branch:** `worktree-mobile-electron-parity-v2`
**Scope:** Drift since 2026-05-21, gap recheck, DRY opportunities, test delta, billing wiring.

---

## D — Drift Since 2026-05-21 (electron added, mobile does not have)

### D-001 | P2P Book-Sharing System | SEVERITY: P1
Electron gained a complete multi-user P2P book-sharing subsystem with no mobile equivalent. Files: `apps/rishi-electron/src/renderer/src/actors/sharing/` (11 actor files including `signalingActor.ts`, `peerWrapperActor.ts`, `hostFileSenderActor.ts`, `viewerFileReceiverActor.ts`, `syncActor.ts`, etc.), `apps/rishi-electron/src/renderer/src/components/sharing/` (15 UI components including `SharingSessionOverlay.tsx`, `SessionPanel.tsx`, `InvitePanel.tsx`, `ParticipantTile.tsx`, `MicChip.tsx`), `apps/rishi-electron/src/renderer/src/machines/sessionMachine.ts`. The `sessionMachine.ts:1-30` imports from `@rishi/sharing-protocol/schemas`. Zero files in `apps/mobile` reference sharing, sessionMachine, or P2P. This feature was never tracked in `.parity/GAP-ANALYSIS.md`. Decision needed: (a) build for mobile, (b) explicitly defer, or (c) mark mobile-forever-out-of-scope.

### D-002 | Navigation History Machine (back/forward pill + chapter resume) | SEVERITY: P2
`apps/rishi-electron/src/renderer/src/machines/navigationHistory/` contains `navigationHistoryMachine.ts`, `navigationHistoryActor.ts`, `pageKey.ts`, `types.ts`. Machine tracks a per-book position stack with `STACK_MAX_DEPTH`, `DWELL_MS`, and emits a back-pill UI. Mobile has no equivalent. `navigationHistoryMachine.ts:20` calls `setup({})` from XState. No files under `apps/mobile` reference `navigationHistory`. Not tracked in original gap analysis.

### D-003 | Billing: `requireActiveSubscription` gate wires 4 AI endpoints | SEVERITY: P0
`workers/worker/src/index.ts:263,314,347,383` adds `requireActiveSubscription` middleware to `/api/audio/speech`, `/api/realtime/client_secrets`, `/api/text/completions`, and `/api/embed`. This gate returns `402 BILLING_INACTIVE` when a user's subscription is `null`, `past_due`, `canceled`, or `unpaid`. Neither client (electron or mobile) handles the `402` response gracefully — no test in `apps/mobile/__tests__/` or `apps/rishi-electron/src/renderer/src/` matches `BILLING_INACTIVE` or `402`. Users with lapsed subscriptions will see raw network errors, not a payment-required UI. `workers/worker/src/billing/sub-gate.ts:57` confirms the response shape: `{ error, code: "BILLING_INACTIVE", subscriptionStatus }`.

### D-004 | Billing: `POST /api/billing/realtime-usage` endpoint added, no client caller | SEVERITY: P0
`workers/worker/src/index.ts:242-252` registers the endpoint. `workers/worker/BILLING-HANDOFF.md:110-111` explicitly states: "client never calls `POST /api/billing/realtime-usage`. This is a real revenue leak." Zero matches for `api/billing/realtime-usage` anywhere under `apps/`. Both clients are unaffected by the recent "wire mobile/electron voice-chat to realtime usage reporting" commits — those commits added only the worker endpoint and validation; no client-side caller was ever written.

### D-005 | Billing: `GET /api/billing/portal` endpoint added, no UI link anywhere | SEVERITY: P2
`workers/worker/src/billing/portal.ts` provides a Customer Portal URL. No link/button exists in `apps/mobile/app/(tabs)/settings/index.tsx` or `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx`. `workers/worker/BILLING-HANDOFF.md` lists "billing portal in settings UI" as gap #7 in the remaining work list.

### D-006 | `onCustomerCreate` idempotency commit landed | SEVERITY: P1 (EBUG-001 status change)
Commit `9a766143` (`feat(billing): make onCustomerCreate idempotent`) landed after the billing system went live. The code at `workers/worker/src/auth.ts:76-83` now calls `applyWelcomeCreditAndSubscription`. However the current implementation at `workers/worker/src/billing/stripe.ts:21-42` has NO idempotency guard — it unconditionally calls `stripe.customers.createBalanceTransaction` and `stripe.subscriptions.create`. If the Better Auth Stripe plugin fires `onCustomerCreate` twice (signup retry, webhook replay), the user receives $2 credit and two subscriptions. This is EBUG-001 (see Electron-Side Bugs section).

### D-007 | `rishimobile://` trusted origin added to worker | SEVERITY: INFO (positive)
`workers/worker/src/auth.ts:27` now lists `trustedOrigins: [env.PUBLIC_WEB_URL, "rishi-electron://", "rishimobile://"]`. This is correct and unblocks mobile OAuth deep-link auth. Mobile-side wiring (`apps/mobile`) is complete — the Better Auth PKCE flow in `apps/mobile/lib/auth/` uses this.

### D-008 | Existing-user backfill script landed | SEVERITY: P1
Commit `88ca71df` added a backfill script for existing users without `stripe_customer_id`. This is worker-side only. Mobile and electron clients do not need changes, but operators must run this script before going live, or pre-billing users will receive `402` on all AI endpoints.

### D-009 | `react-native-worklets` at 0.5.1 — G19 local VAD blocker is lifted | SEVERITY: P2
`apps/mobile/package.json:67` pins `"react-native-worklets": "0.5.1"`. The original G19 blocker in `.parity/GAP-ANALYSIS.md:29` cited needing `>= 0.6.0` for the worklet thread. npm shows 0.9.1 is current. The blocker is technically cleared; a version bump to 0.9.1 would unlock local-VAD implementation. See also G-001 below.

### D-010 | Electron TTS service NOT updated to consume `@rishi/shared/tts` | SEVERITY: P1
After parity-v1 added `packages/shared/src/tts/`, electron's TTS service at `apps/rishi-electron/src/renderer/src/services/tts/service.ts` was NOT refactored. It remains a local copy and calls `URL.createObjectURL(new Blob([cached], { type: 'audio/mpeg' }))` at lines 30 and 40 directly, whereas `packages/shared/src/tts/service.ts` adds an injectable `makeAudioUri` port that defaults to the same call on non-mobile platforms. Electron has `linkOrCopyFile` in `TtsIpcChannels` (electron's `types.ts:61`) which is missing from the shared `TtsIpcChannels` (`packages/shared/src/tts/types.ts:59-69`) — this means the shared IPC interface is missing the hardlink optimization.

### D-011 | Electron voice-chat service NOT consuming `@rishi/shared/voice-chat` | SEVERITY: P1
`apps/rishi-electron/src/renderer/src/services/voice-chat/` (service.ts, machine.ts, types.ts, key-cache.ts, emitter.ts, errors.ts, activation-program.ts, local-vad.ts) are all local files. None import from `@rishi/shared`. `service.ts:9` hardcodes `import { captureError } from '@/utils/sentry'` while the shared version uses an optional `captureError` port. Mobile imports the shared implementation from `@rishi/shared/voice-chat`.

### D-012 | Electron `buildRealtimeAgent.ts` inlines prompt-render helpers from shared | SEVERITY: P1
`apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-158` defines `renderOutlineSection`, `renderActiveParagraphSection`, `renderVisualSection` as local functions. `packages/shared/src/voice-chat/build-realtime-agent.ts` exports the same helpers plus `renderRealtimeInstructions`. Mobile's `apps/mobile/lib/voice-chat/realtime-session.ts:46` correctly imports `renderRealtimeInstructions` from shared. Electron does not import from shared — the inline copies will diverge silently over time.

### D-013 | Electron book-import service NOT consuming `@rishi/shared/book-import` | SEVERITY: P1
`apps/rishi-electron/src/renderer/src/services/book-import/` (service.ts, importer.ts, indexer.ts, dispatch.ts, emitter.ts, types.ts, scanner-adapter.ts) are all local. No `import from '@rishi/shared'` found in any of these files. Electron's `types.ts:13` lists `BookFormat = 'epub' | 'pdf' | 'mobi' | 'azw3'` (no `djvu`), while `packages/shared/src/book-import/types.ts:20` lists `'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'`. DJVU import is supported in shared but not in electron's local copy.

---

## G — Gap Recheck (original `.parity/GAP-ANALYSIS.md` deferred items)

### G-001 | G19: Local VAD — BLOCKER LIFTED | STATUS: READY TO IMPLEMENT
Original blocker: "Algorithm portable, Web Audio API not." Re-check: `apps/mobile/package.json:67` has `"react-native-worklets": "0.5.1"`. npm shows 0.9.1 is the latest (worklet-thread support added at 0.6.0 per prior research). Bumping to `^0.9.1` and porting `packages/shared/src/voice-chat/local-vad.ts` to use `react-native-worklets` would implement G19. No new architectural blocker exists. Effort: M (matching original estimate).

### G-002 | G30: Page-curl — BLOCKER UNCHANGED | STATUS: DEFERRED
Electron's `apps/rishi-electron/src/renderer/src/components/pagecurl/drawPageCurl.ts` uses Canvas 2D API directly. The original note says `@shopify/react-native-skia` is needed. `apps/mobile/package.json` does not include `@shopify/react-native-skia`. Effort and risk classification unchanged from original. Not blocking any P0/P1 path.

### G-003 | G31: AI Chat Orb (floating) — PARTIALLY ADDRESSED | STATUS: UNBLOCKED
`apps/mobile/components/chat/AIChatOrb.tsx` and `apps/mobile/components/reader/ReaderOverlay.tsx` exist in the current tree. The `.parity-v2/phase6-critique/VALIDATED.md:P1-M` confirms the orb and VoiceLauncher exist but have a z-index overlap issue with the reader bottom bar (WGT-003). The feature exists on mobile; the remaining gap is the z-index/offset layering bug, not a missing feature.

### G-004 | G24/G25: Zustand stores + XState machines — FULLY CLOSED | STATUS: DONE
All 11 Zustand stores landed on mobile (authStore, chatStore, playerStore, pdfStore, prefsStore, tutorialStore confirmed in `apps/mobile/lib/stores/`). All 4 XState machines landed: `playerMachine`, `pdfReaderMachine`, `connectivityMachine` (all in `packages/shared/src/machines/`). The VALIDATED.md confirms no P0/P1 findings against these.

### G-005 | G32: Cover-image extraction — NEEDS RECHECK | STATUS: PARTIAL
`apps/mobile/lib/book-import/adapters.ts` is referenced in `.parity-v2/phase6-critique/VALIDATED.md:P1-AC` as having cover-extraction failures that leave a letter-tile with no retry. The mechanism exists but has an error-state UX gap. The shared `packages/shared/src/formats/epub-cover.ts` handles extraction. The gap is now a UX/error-surface issue, not a missing feature.

### G-006 | G21: Realtime agent prompts — ELECTRON STILL DIVERGENT | STATUS: OPEN
See D-012. Mobile is DRY (uses `renderRealtimeInstructions` from shared). Electron has inline local copies in `buildRealtimeAgent.ts:114-158`. As long as electron does not consume the shared function, a prompt change in `packages/shared/src/voice-chat/build-realtime-agent.ts` will be reflected on mobile but NOT on electron. Behavioral divergence risk is HIGH since the prompts determine how the AI model responds.

### G-007 | G20: Voice-chat page-capture vision tool — EXISTS ON BOTH | STATUS: CLOSED
`apps/mobile` has `react-native-view-shot` at `^5.1.0` (`apps/mobile/package.json:63`). `ReaderOverlay.tsx` wires `captureCurrentPage`. Electron has `modules/pageCapture/`. Both platforms have the feature. VALIDATED.md has no P0/P1 finding against this.

### G-008 | G11: EPUB bookmarks — STATUS: CLOSED
`apps/mobile/__tests__/bookmarks/bookmark-storage.test.ts` exists. `apps/mobile/components/reader/ReaderShell.tsx` receives `onBookmarkTogglePress`. Validated in VALIDATED.md. Closed.

### G-009 | G22: Ready chime + thinking sound — STATUS: DEFERRED (P3, unchanged)
Original: "expo-audio." `apps/mobile/package.json:27` includes `"expo-audio": "~1.1.1"` — the dependency exists. Implementation not found in `apps/mobile/lib/voice-chat/`. Blocker: not a build/dependency blocker, just not implemented. P3 deferred status unchanged.

### G-010 | CHUNK-ID DIVERGENCE — STATUS: NEEDS INVESTIGATION
The original gap analysis mentioned chunk-ID divergence between electron and mobile. `packages/shared/src/book-import/indexer.ts` and electron's `apps/rishi-electron/src/renderer/src/services/book-import/indexer.ts` are separate copies. If chunk ID generation logic diverges, the same book embedded on both platforms produces incompatible vector stores. No test currently validates cross-platform chunk ID parity. See T-004.

---

## R — DRY Opportunities (code duplicated between electron local copies and shared/mobile)

### R-001 | Voice-chat service directory | RISK: L2 MEDIUM
`apps/rishi-electron/src/renderer/src/services/voice-chat/` (8 files) vs `packages/shared/src/voice-chat/` (same 8 files). Electron's version hardcodes `captureError` from `'@/utils/sentry'` at `service.ts:9`. Shared version uses optional port. Migration path: replace electron's `captureError` import with the optional port, wire `captureError: sentry.captureError` at the electron factory call site in `services/index.ts`. Risk: Electron has 4 test files (emitter.test, errors.test, key-cache.test, machine.coverage.test) that would need to move or re-point to shared tests. The shared versions of these files already exist.

### R-002 | TTS service directory | RISK: L2 MEDIUM
`apps/rishi-electron/src/renderer/src/services/tts/` (9 files) vs `packages/shared/src/tts/` (same 9 files). Divergence: electron's `TtsIpcChannels` has `linkOrCopyFile` (`types.ts:61`) missing from shared. Electron's `service.ts:30,40` calls `URL.createObjectURL` directly instead of using the injectable `makeAudioUri` port. Migration: add `linkOrCopyFile` to shared `TtsIpcChannels`, add `makeAudioUri` with a `URL.createObjectURL` default in the shared service (already present there). Electron simply passes its IPC as-is.

### R-003 | Book-import service directory | RISK: L2 MEDIUM
`apps/rishi-electron/src/renderer/src/services/book-import/` (7 files) vs `packages/shared/src/book-import/` (7 files). Divergence: electron's types miss `djvu` format (`types.ts:13`). Electron has `DiscoveryEvent`/scanner machinery (`service.ts:15-118`) not in shared (shared's `types.ts:7` explicitly documents the scanner port was dropped). Migration: add `djvu` to electron's `BookFormat`, wire `DiscoveryEvent` as an electron-specific extension that wraps the shared service. Mobile already imports from shared at `apps/mobile/lib/book-import/index.ts:6`.

### R-004 | `buildRealtimeAgent.ts` prompt-render helpers | RISK: L1 SAFE
`apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-158` (`renderOutlineSection`, `renderActiveParagraphSection`, `renderVisualSection`) are byte-for-byte copies of the same functions in `packages/shared/src/voice-chat/build-realtime-agent.ts`. Safe to delete from electron and `import { renderRealtimeInstructions } from '@rishi/shared/voice-chat/build-realtime-agent'`. Mobile already does this at `apps/mobile/lib/voice-chat/realtime-session.ts:46`. No behavioral risk.

### R-005 | Billing cost types used only in worker but declared in shared | RISK: L1 SAFE (already done correctly)
`packages/shared/src/billing/cost.ts`, `default-rates.ts`, `stripe-config.ts` are correct shared location. Worker imports them. No duplication exists — this R-entry is informational: the pattern is correct and should be maintained for any future billing rate additions.

### R-006 | `chatStore.setChatVoicePort` wired in tests but dead in production | RISK: L1 SAFE (cleanup)
`apps/mobile/lib/stores/chatStore.ts:83` exports `setChatVoicePort`. It is called in test files (`chatStore.test.ts:46`, `useVoiceChat.test.ts:37`) but zero production callers exist under `apps/mobile/app/`. The port stays as `noopPort` in production forever, meaning `useChatStore().voiceState` is permanently `'idle'` at the app level. The gap: whoever constructs the voice-chat service (presumably in an `_layout.tsx` or provider) must call `setChatVoicePort(service)` once at startup. This is a wiring omission, not a DRY issue.

### R-007 | Navigation history machine: electron-only, no shared candidate yet | RISK: L3 RISKY
`apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts` has no shared equivalent. Moving it to shared requires the `AnchorPoint` type (`types.ts:4`) to be platform-neutral. On mobile, the "pill" UI would need to use Reanimated instead of CSS transitions. Do not move to shared until mobile implements equivalent UX. Mark as electron-only for now.

### R-008 | Electron session machine depends on `@rishi/sharing-protocol` | RISK: L3 RISKY
`apps/rishi-electron/src/renderer/src/machines/sessionMachine.ts:12` imports from `@rishi/sharing-protocol/schemas`. This package uses zod v4. The file comments at line 22-27 explain why sharing-protocol cannot be consumed via `import type` without breaking XState's setup() inference. Do NOT share until the zod v4 type-cascade issue is resolved.

### R-009 | `linkOrCopyFile` optimization missing from shared TTS IPC | RISK: L2 MEDIUM
`apps/rishi-electron/src/renderer/src/services/tts/types.ts:56-62` documents `linkOrCopyFile` (hardlink src→dest, falls back to copyFile on EXDEV). `packages/shared/src/tts/types.ts:59-68` does not include it. If electron migrates to shared TTS, this optimization will be silently dropped, causing 2x disk usage for TTS cache texthash mirrors. Must add `linkOrCopyFile?: (src: string, dest: string) => Promise<void>` as optional to shared `TtsIpcChannels` before migration.

---

## T — Test / Reliability Delta (mobile thinner than electron on shared surfaces)

### T-001 | No test for `402 BILLING_INACTIVE` response handling in either client | SEVERITY: P0
`workers/worker/src/billing/sub-gate.ts:57` returns `{ error, code: "BILLING_INACTIVE" }` when subscription status blocks. Zero tests in `apps/mobile/__tests__/` or `apps/rishi-electron/src/renderer/src/` cover this response code. Both clients will surface raw network errors to users with lapsed subscriptions.

### T-002 | `setChatVoicePort` never called in production — untested | SEVERITY: P1
`apps/mobile/lib/stores/chatStore.ts:83` and its test coverage at `apps/mobile/__tests__/stores/chatStore.test.ts:46` verify the port can be injected. But the startup wiring (which layout or provider calls `setChatVoicePort(realService)`) is absent and untested. Test needed: an integration test that simulates app startup and verifies `useChatStore().voiceState` transitions out of `'idle'` when a voice session begins.

### T-003 | Mobile voice-chat `response.done` discards billing token counts — untested | SEVERITY: P0
`apps/mobile/lib/voice-chat/realtime-session.ts:276-278`: `case 'response.done': emit('agent_end') break`. The `response.done` event payload contains `output[].usage` with `audioInputTokens`, `audioOutputTokens`. These are silently discarded. No test verifies that token counts are extracted. The billing path after session end is never exercised in any test.

### T-004 | Chunk-ID cross-platform parity has no regression test | SEVERITY: P1
Electron's `services/book-import/indexer.ts` and `packages/shared/src/book-import/indexer.ts` are separate copies. A unit test is needed that feeds the same raw book bytes through both paths and asserts identical chunk IDs. Without this, a change to either indexer creates a silent vector-store incompatibility for books that were indexed on one platform and queried on the other.

### T-005 | `buildRealtimeAgent` prompt divergence has no cross-platform assertion | SEVERITY: P1
Electron's inline `renderOutlineSection`/`renderActiveParagraphSection` (at `buildRealtimeAgent.ts:114-158`) and the shared `renderRealtimeInstructions` (at `packages/shared/src/voice-chat/build-realtime-agent.ts`) have no test that asserts both produce identical output for the same inputs. If they diverge, users on mobile and electron experience different AI behavior with no observable signal.

### T-006 | Electron's `buildRealtimeAgent.test.ts` covers local copy, not shared module | SEVERITY: P2
`apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts` tests the local inline helpers. `packages/shared/src/voice-chat/build-realtime-agent.test.ts` tests the shared module. These are parallel test suites that must be kept in sync. Currently any behavioral difference between them would pass all tests.

### T-007 | P0-O activation context wiring is PARTIAL — pageText is not full DOM text | SEVERITY: P1
All four readers now wire `getActivationContext`:
- EPUB (`apps/mobile/app/reader/[id].tsx:761`): `pageText: chapterLabel ?? ''` — chapter label only, NOT rendered DOM text.
- PDF (`apps/mobile/app/reader/pdf/[id].tsx:700-702`): `pageText: 'Page N of M'` — page number string, not text content.
- MOBI (`apps/mobile/app/reader/mobi/[id].tsx:699`): `pageText: 'Chapter N'` — chapter index only.
- DJVU (`apps/mobile/app/reader/djvu/[id].tsx:577-579`): `pageText: 'Page N of M'` — page number, not content.

Electron passes full rendered DOM text to the realtime agent. Mobile passes only stub strings. The AI model has no page content to reason over on mobile.

### T-008 | No integration test for the full sign-up billing path (customer + credit + subscription) | SEVERITY: P1
`workers/worker/BILLING-HANDOFF.md:100-104` lists the expected test outcomes for the billing flow. `workers/worker/src/billing/stripe.test.ts` covers unit logic. However no end-to-end integration test exists that mounts the Better Auth middleware, triggers `onCustomerCreate`, and verifies exactly one subscription and one `$-1.00` balance transaction are created. The idempotency scenario (double-click signup) is called out as untested.

---

## B — Billing Wiring Symmetry (electron vs mobile)

### B-001 | CRITICAL: Neither client calls `POST /api/billing/realtime-usage` | SEVERITY: P0
`workers/worker/src/index.ts:242-252` — endpoint exists, accepts `{ audioInputTokens, audioOutputTokens, textInputTokens, textOutputTokens }`, meters via `meterFromContext`. Zero grep matches for `api/billing/realtime-usage` under `apps/`. `workers/worker/BILLING-HANDOFF.md:106-111` explicitly confirms: "client never calls `POST /api/billing/realtime-usage`. This is a real revenue leak that goes live the moment we go live." Symmetric: both clients are equally broken on this path.

### B-002 | Mobile: `response.done` discards token counts needed for B-001 | SEVERITY: P0
`apps/mobile/lib/voice-chat/realtime-session.ts:276-278` receives `response.done` events but only emits `'agent_end'` without extracting `usage`. The fix requires extracting `(msg as ResponseDoneMsg).response?.usage?.input_audio_tokens` (and output equivalent) and calling `mobileVoiceChatIpc.reportUsage(counts)`. The `VoiceChatIpc` type at `apps/mobile/lib/voice-chat/ipc.ts` has no `reportUsage` method — it must be added to both the interface and the implementation.

### B-003 | Electron: equivalent `response.done` handler not found — event may not exist in electron SDK | SEVERITY: P0
Electron uses `@openai/agents/realtime` SDK (not raw WebRTC data-channel events). Grep for `response.done` in `apps/rishi-electron/` returns zero matches. The SDK abstracts away raw events. The billing hook for electron must be found in the SDK's session lifecycle callbacks (likely `onSessionEnd` or `onResponseComplete`), not a raw event listener. `apps/rishi-electron/src/renderer/src/services/index.ts:379` has a comment about billing stopping when inactivity closes the session, confirming the topic was considered but not wired.

### B-004 | `VoiceChatIpc` interface missing `reportUsage` — must be added symmetrically | SEVERITY: P1
`packages/shared/src/voice-chat/types.ts` defines `VoiceChatIpc` (or equivalent). `apps/mobile/lib/voice-chat/ipc.ts` implements `getRealtimeClientSecret` and `transcribeAudio`. No `reportUsage` method. Adding billing wiring requires: (1) adding `reportUsage(usage: RealtimeUsage): Promise<void>` to the shared `VoiceChatIpc` type, (2) implementing it in mobile's `mobileVoiceChatIpc`, (3) finding the equivalent electron IPC injection point in `services/index.ts`, and (4) calling it in the session's `response.done` / session-end lifecycle.

---

## ELECTRON-SIDE BUGS

### EBUG-001 | `applyWelcomeCreditAndSubscription` has no idempotency guard | SEVERITY: P1
`workers/worker/src/billing/stripe.ts:21-42` creates a balance transaction (`-$1.00`) and a subscription unconditionally. If `onCustomerCreate` fires twice (double-click signup, webhook replay, cold-start retry), the user gets `$2.00` credit and two active subscriptions. The commit message `feat(billing): make onCustomerCreate idempotent` is misleading — looking at the current code, NO idempotency guard exists in the file. The fix requires either: (a) checking `stripe.subscriptions.list({ customer: id, status: 'all', limit: 1 })` before creating, or (b) using Stripe idempotency keys derived from the customer ID.

### EBUG-002 | Electron `buildRealtimeAgent.ts` does not consume shared `renderRealtimeInstructions` | SEVERITY: P1
`apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-158` inlines `renderOutlineSection`, `renderActiveParagraphSection`, `renderVisualSection` locally. `packages/shared/src/voice-chat/build-realtime-agent.ts` exports `renderRealtimeInstructions` which wraps all three. If the shared prompt is updated (e.g., a new language label, a new visual-context policy), electron's inline copies will not receive the update. Mobile users and electron users will diverge in AI behavior with no compile-time signal.

### EBUG-003 | Electron's `BookFormat` missing `djvu` while shared type includes it | SEVERITY: P2
`apps/rishi-electron/src/renderer/src/services/book-import/types.ts:13`: `type BookFormat = 'epub' | 'pdf' | 'mobi' | 'azw3'`. `packages/shared/src/book-import/types.ts:20`: `type BookFormat = "epub" | "pdf" | "mobi" | "azw3" | "djvu"`. DJVU books imported on mobile will generate chunks with `format: 'djvu'`. If any cross-platform sync path reaches electron, the missing union member could cause silent type mismatches in indexer/importer logic.

---

## Summary counts

| Category | Count | P0 | P1 | P2 |
|---|---|---|---|---|
| D — Drift findings | 13 | 2 (D-003, D-004) | 6 (D-001, D-006, D-008, D-010, D-011, D-012) | 5 |
| G — Gap recheck | 10 | 0 | 4 (G-001, G-006, G-010, G-007) | 6 |
| R — DRY opportunities | 9 | 0 | 5 (R-001–R-005) | 4 |
| T — Test delta | 8 | 2 (T-001, T-003) | 5 (T-002, T-004, T-005, T-007, T-008) | 1 |
| B — Billing wiring | 4 | 2 (B-001, B-002) | 2 (B-003, B-004) | 0 |
| EBUG — Electron bugs | 3 | 0 | 2 (EBUG-001, EBUG-002) | 1 |
| **Total** | **47** | **6** | **24** | **17** |
