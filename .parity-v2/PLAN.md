# PLAN.md — Mobile/Electron Parity v2 Build Plan

**Plan date:** 2026-06-04 (revised post-REVIEW-01)
**Spec source:** `.parity-v2/SPEC.md` (11 in-scope items; 3 done-on-main; 6 deferred)
**Methodology:** Test-driven (red → green → refactor). Every task lists its red-phase test BEFORE implementation.

**Orchestrator-locked decisions (constraints on this plan):**
- **A. (REVISED)** BILLING-001 is closed on `main` (see SPEC §4.0a). No SDK spike required this round.
- **B.** NAVHIST-001 lifts the machine to `packages/shared/src/machines/navigationHistory/` using `Record<string, AnchorPoint>` for `resumeMap` (per REVIEW-01 MINOR-05). Electron migrates to consume it. R-007 closes as a byproduct.
- **C.** VAD-001: if `react-native-worklets@^0.6.0` (or higher compatible) breaks Reanimated peer-deps OR `react-native-webrtc` does not expose raw PCM, DEFER without scope expansion. Phase-0 spike (T-P0.1) gates this commitment.

**Revision log (REVIEW-01 deltas):**
- REMOVED T-P0.1 (SDK spike — BILLING-001 closed)
- REMOVED T-P1.1 (RealtimeUsage shared types — already shipped)
- REMOVED T-P1.2 (retryWithBackoff — bundled in shared billing client already)
- REMOVED T-P2.2 (mobile BILLING-001 half — already implemented)
- REMOVED T-P2.4 (BILLING-003 mobile half — already implemented)
- REMOVED T-P4.1 (EBUG-FIX-001 — already idempotent)
- REMOVED T-P4.2 (electron BILLING-001 half — already implemented)
- REMOVED T-P5.3 (billing flow integration test — coverage already exists in shared)
- ADDED T-P2.2 (BILLING-AUDIT-001 mobile integration test)
- ADDED T-P2.4 (BILLING-003 mobile-test presence audit — 5-min verification)
- ADDED T-P3.6 (electron `services/index.ts` wiring-merge — addresses MAJOR-03 file-conflict risk)
- UPDATED T-P0.0 (preflight only; renumbered spikes T-P0.1 / T-P0.2)
- UPDATED T-P1.3 acceptance to include `{ status: 402, body: 'not-json' }` no-throw case (MINOR-02)
- UPDATED T-P1.6 to specify `resumeMap: Record<string, AnchorPoint>` (MINOR-05)
- UPDATED T-P2.1 acceptance to mount in two auth states (MAJOR-06)
- UPDATED T-P3.1 reviewer file-count gate to 17 (9 src + 8 test) — actual `ls` count (MINOR-03 + REVIEW-02 MINOR-NEW-01 fix)

---

## 0. Test Runners (verified)

| Surface | Runner | Invocation |
|---|---|---|
| `packages/shared` | vitest | `pnpm --filter @rishi/shared test` |
| `apps/rishi-electron` | vitest | `pnpm --filter rishi-electron test` |
| `workers/worker` | vitest | `pnpm --filter worker test` (script: `vitest run`) |
| `apps/mobile` | jest | `pnpm --filter rishi-mobile exec jest` — no `test` script in package.json; **TDD task T-P0.0 adds one** (`"test": "jest"`) |

Test files live next to source for shared/electron/worker (`*.test.ts(x)`). Mobile uses `apps/mobile/__tests__/` mirroring the source tree.

---

## Phase 0 — Spikes (read-only investigations, no production code)

### T-P0.0 — Add `test` script to `apps/mobile/package.json`
- **Source spec:** all mobile items (preflight)
- **Inputs:** `apps/mobile/package.json`
- **Outputs:** MODIFIED `apps/mobile/package.json` (add `"test": "jest"`, `"test:watch": "jest --watch"`)
- **Tests:** existing `apps/mobile/__tests__/chunker.test.ts` runs via `pnpm --filter rishi-mobile test`
- **Independence:** none (gate for all mobile work)
- **Reviewer focus:** does the new script integrate with `jest.config.js` without changing existing CI behavior?

### T-P0.1 — `react-native-worklets` / `react-native-webrtc` compat spike (VAD-001 prerequisite)
- **Source spec:** VAD-001 (§3.10)
- **Inputs (READ):** `apps/mobile/package.json`, `react-native-worklets@^0.6.0` changelog (via npm registry), `react-native-webrtc`'s `MediaStreamTrack` / audio-frame API surface, `apps/mobile/lib/voice-chat/media-port.ts`
- **Outputs:** CREATED `.parity-v2/VAD-COMPAT-SPIKE.md` with:
  1. Highest `react-native-worklets` version that satisfies the current Reanimated peer-dep.
  2. Yes/no on raw-audio access from `react-native-webrtc` (specific API and platforms).
  3. **Branch A:** both green → VAD-001 stays in Phase 2.
  4. **Branch B:** either red → VAD-001 deferred (per orchestrator constraint C); writes `.parity-v2/VAD-001-investigation.md` per spec §3.10 acceptance criterion 5.
- **Tests:** none (investigation only)
- **Independence:** parallel with T-P0.2
- **Reviewer focus:** is the deferral evidence-based (link to issues / source)? Are the version constraints exact?

### T-P0.2 — Chunk-ID parity baseline check (DRY-005 prerequisite)
- **Source spec:** DRY-005 (§3.7)
- **Inputs (READ):** `packages/shared/src/book-import/indexer.ts`, `apps/rishi-electron/src/renderer/src/services/book-import/indexer.ts`
- **Outputs:** CREATED `.parity-v2/CHUNK-ID-SPIKE.md` documenting:
  1. ID strategy of each indexer (content-addressable vs positional).
  2. Whether `{ id, pageNumber, data }` would be deep-equal on the same input today.
  3. Decision: ship `test.failing` (per orchestrator Q4) OR upgrade DRY-005 scope to align IDs.
- **Tests:** none (investigation only)
- **Independence:** parallel with T-P0.1
- **Reviewer focus:** if `test.failing` is chosen, is a follow-up alignment issue queued?

---

## Phase 1 — Shared API forward-compatibility (red tests + additive shared exports)

**Goal:** add new exports/types to `packages/shared` without breaking existing consumers. All tasks here are parallelizable (independent files). Each task RED test ships first.

### T-P1.3 — `BillingInactiveError` + interceptor
- **Source spec:** BILLING-002 (§3.2)
- **Inputs (READ):** `workers/worker/src/billing/sub-gate.ts:57`, `packages/shared/src/billing/` (existing files)
- **Outputs:**
  - CREATED `packages/shared/src/billing/errors.ts` — `BillingInactiveError` (extends `Error`, `readonly code = 'BILLING_INACTIVE'`, `subscriptionStatus: string | null`) + `isBillingInactiveResponse(status, body)` type guard.
  - CREATED `packages/shared/src/billing/interceptor.ts` — `checkBillingGate(response: Response): Promise<void>` (clones the response so the body remains readable downstream).
  - MODIFIED `packages/shared/src/billing/index.ts` (barrel) — re-exports errors + interceptor + existing cost/default-rates/stripe-config/realtime-usage-*.
  - MODIFIED `packages/shared/package.json` — add `./billing/errors`, `./billing/interceptor` to `exports`.
- **Tests (RED first):** CREATED `packages/shared/src/billing/interceptor.test.ts`:
  1. `{ status: 402, body: { code: 'BILLING_INACTIVE', subscriptionStatus: 'canceled' } }` → throws `BillingInactiveError` with `subscriptionStatus === 'canceled'`.
  2. `{ status: 200 }` → no throw.
  3. `{ status: 402, body: { error: 'something else' } }` → no throw (passes through).
  4. **(MINOR-02)** `{ status: 402, body: 'not-json' }` (body fails `JSON.parse`) → no throw; original response remains readable to caller.
  5. Error instances: `instanceof BillingInactiveError`, `err.code === 'BILLING_INACTIVE'`.
  6. Response body is still readable after `checkBillingGate` (clone semantics).
- **Independence:** parallel with T-P1.4..T-P1.6
- **Reviewer focus:** confirm body-clone semantics; confirm interceptor does not throw on JSON-parse failure for non-`BILLING_INACTIVE` 402s; confirm no DOM `Response` dependency that breaks Node test envs.

### T-P1.4 — `TtsIpcChannels.linkOrCopyFile` optional + cache preference
- **Source spec:** DRY-002 (§3.4)
- **Inputs (READ):** `packages/shared/src/tts/types.ts:64`, `packages/shared/src/tts/cache.ts:84`, `packages/shared/src/tts/service.ts` (verify `makeAudioUri` site per §3.4 investigation correction), `packages/shared/src/tts/cache.test.ts`
- **Outputs:**
  - MODIFIED `packages/shared/src/tts/types.ts` — add optional `linkOrCopyFile?(src, dest): Promise<void>` on `TtsIpcChannels`.
  - MODIFIED `packages/shared/src/tts/cache.ts` — `const linkOrCopy = ipc.linkOrCopyFile ?? ipc.copyFile; await linkOrCopy(src, mirror)`.
  - MODIFIED `packages/shared/src/tts/service.ts` IF the investigation confirms inline `URL.createObjectURL` — change to `deps.makeAudioUri?.(blob) ?? URL.createObjectURL(blob)`. Otherwise document the existing port use in the PR body.
- **Tests (RED first):** EXTEND `packages/shared/src/tts/cache.test.ts` — new case: both `linkOrCopyFile` and `copyFile` provided; assert `linkOrCopyFile` is called and `copyFile` is not; legacy case (only `copyFile`) still uses `copyFile`. If `service.ts` changes: add to `packages/shared/src/tts/service.test.ts` asserting `makeAudioUri` is preferred when supplied.
- **Independence:** parallel with T-P1.3, T-P1.5, T-P1.6
- **Reviewer focus:** non-breaking (electron's existing `copyFile`-only path still works); investigation-gate decision on `makeAudioUri` is recorded.

### T-P1.5 — `BookFormat` re-export verification (DRY-003 prep)
- **Source spec:** DRY-003 (§3.5)
- **Inputs (READ):** `packages/shared/src/book-import/types.ts:20`, `packages/shared/src/book-import/index.ts:18`
- **Outputs:** None unless gaps found. Verification step: confirm `BookFormat` includes `'djvu'` AND that `index.ts` exports it. If both hold, **task body is a documentation-only confirmation** — write a short note to the PR body. If a gap is found, MODIFIED `packages/shared/src/book-import/index.ts` to re-export.
- **Tests (RED first):** CREATED `packages/shared/src/book-import/bookFormat-export.test.ts` — imports `BookFormat` from `@rishi/shared/book-import` and asserts the type union contains `'djvu'` (via a `satisfies` round-trip).
- **Independence:** parallel
- **Reviewer focus:** strictly a type-system gate; no runtime change expected.

### T-P1.6 — `navigationHistoryMachine` lifted to `packages/shared/src/machines/navigationHistory/`
- **Source spec:** NAVHIST-001 (§3.11), closes R-007
- **Inputs (READ):** `apps/rishi-electron/src/renderer/src/machines/navigationHistory/{navigationHistoryMachine,navigationHistoryActor,pageKey,types}.ts`, plus existing test files for behavior contract reference
- **Outputs:**
  - CREATED `packages/shared/src/machines/navigationHistory/types.ts` — parametric `PageKey`/`Anchor` types; constants `STACK_MAX_DEPTH`, `DWELL_MS` re-exported. **`resumeMap` is `Record<string, AnchorPoint>` (not `Map`)** per REVIEW-01 MINOR-05 — JSON-serializable for XState devtools/inspectors.
  - CREATED `packages/shared/src/machines/navigationHistory/pageKey.ts` — verbatim port (string-only logic).
  - CREATED `packages/shared/src/machines/navigationHistory/navigationHistoryMachine.ts` — verbatim port of XState `setup()` machine; `Anchor` becomes a generic.
  - CREATED `packages/shared/src/machines/navigationHistory/index.ts` — barrel.
  - MODIFIED `packages/shared/package.json` — add `./machines/navigationHistory` to `exports`.
- **Tests (RED first):**
  - CREATED `packages/shared/src/machines/navigationHistory/pageKey.test.ts` — port of electron's `pageKey.test.ts`.
  - CREATED `packages/shared/src/machines/navigationHistory/navigationHistoryMachine.test.ts` — port of electron's behavior tests (push, pop, depth cap, dwell-gated pill emission, per-book reset). **Add a serialization round-trip test:** `JSON.parse(JSON.stringify(machineSnapshot.context))` preserves `resumeMap` entries.
- **Independence:** parallel (new files only)
- **Reviewer focus:** generic `Anchor` parameterization is correct; no `react`, `dom`, or electron-only imports leak in; XState `setup()` inference still works under generics; `resumeMap` is `Record`, not `Map`; constants match electron file exactly. If electron's local type uses `Map`, electron-side adapter (in T-P3.5) converts at the boundary.

---

## Phase 2 — Mobile changes (consume shared, fix wiring)

**Goal:** mobile gets all the new behavior. Most tasks are independent; NAVHIST-001 mobile-half depends on T-P1.6.

### T-P2.1 — WIRING-001: `setChatVoicePort` startup wiring (auth-gated)
- **Source spec:** WIRING-001 (§3.9)
- **Inputs (READ):** `apps/mobile/lib/stores/chatStore.ts:83` (`setChatVoicePort`), `apps/mobile/app/_layout.tsx`, `apps/mobile/lib/voice-chat/service.ts`, `apps/mobile/lib/stores/authStore.ts` (the auth gate signal: `(s) => s.user && s.sessionToken`), `apps/mobile/__tests__/hooks/useVoiceChat.test.ts:37` (existing fixture reference)
- **Outputs:**
  - CREATED `apps/mobile/lib/voice-chat/buildService.ts` — factory `buildMobileVoiceChatService(): VoiceChatService` assembling `mobileVoiceChatIpc`, `mobileMediaPort`, `mobileEffectsPort` (no-op stub), `mobileClock`, etc.
  - MODIFIED `apps/mobile/app/_layout.tsx` — subscribe to `useAuthStore((s) => s.user && s.sessionToken ? s : null)`. In a `useEffect`, when the signal transitions from `null` → non-null, call `buildMobileVoiceChatService()` + `setChatVoicePort(service)`. Guard with module-level `wired` flag for Fast-Refresh idempotency. Expose `__resetForTests()` (test-only).
- **Tests (RED first):** CREATED `apps/mobile/__tests__/app/startupWiring.test.tsx`:
  - **(MAJOR-06)** Two-state mount test:
    - **State A:** mount provider with `useAuthStore` mocked to return `{ user: null, sessionToken: null }`. Assert `setChatVoicePort` is NOT called.
    - **State B:** mount with `{ user: { id: 'u1', email: 'x' }, sessionToken: 'tok' }`. Assert `setChatVoicePort` called exactly once with a non-noop port.
  - Hot-reload: re-mount in State B; assert NOT called a second time (guarded by `wired` flag).
  - Transition: mount in State A, then update store to State B; assert `setChatVoicePort` is called exactly once after transition.
- **Independence:** only mobile preflight (T-P0.0). Parallel with T-P2.3..T-P2.6 except where noted.
- **Reviewer focus:** Fast-Refresh idempotency; auth race is verifiably gated (the State A assertion catches construction-before-auth); `__resetForTests` is only exposed under `__DEV__` or `process.env.NODE_ENV === 'test'`.

### T-P2.2 — BILLING-AUDIT-001: mobile realtime-usage integration test (NEW)
- **Source spec:** BILLING-AUDIT-001 (§3.1)
- **Inputs (READ):** `apps/mobile/lib/voice-chat/realtime-session.ts:280-298` (existing `case 'response.done'` → `usage.add(...)`), `apps/mobile/lib/voice-chat/realtime-session.ts:364-374` (existing `close()` → `usage.flush()` + `void reportRealtimeUsage(apiClient, total)`), `packages/shared/src/billing/realtime-usage-accumulator.ts`, `packages/shared/src/billing/realtime-usage-client.ts`
- **Outputs:**
  - CREATED `apps/mobile/__tests__/voice-chat/billingReport.integration.test.ts`:
    1. Construct mobile session factory with a mocked `apiClient`.
    2. Drive a synthetic `response.done` event with `usage: { input_token_details: { audio_tokens: 100, text_tokens: 50 }, output_token_details: { audio_tokens: 200, text_tokens: 75 } }`.
    3. Call `session.close()`.
    4. Assert `apiClient` invoked exactly once with `POST /api/billing/realtime-usage` and a body matching `workers/worker/src/index.ts:242-252` shape.
  - Electron audit (PR-body only): `grep -rn "reportRealtimeUsage" apps/rishi-electron/src` → document the test files found. If none assert wiring, open a follow-up issue (do NOT author electron tests in this round).
- **Tests (RED first):** the integration test itself.
- **Independence:** depends only on T-P0.0. Parallel with T-P2.1, T-P2.3..T-P2.6.
- **Reviewer focus:** test is hermetic (mocks `apiClient`, no live worker); field-name mapping matches the existing accumulator (audio + text in/out); zero changes to production code in `apps/mobile/lib/voice-chat/` or `packages/shared/`.

### T-P2.3 — BILLING-002 mobile half: 402 interceptor + modal
- **Source spec:** BILLING-002 (§3.2)
- **Inputs (READ):** `apps/mobile/lib/api.ts`, `apps/mobile/app/_layout.tsx`, `apps/mobile/lib/stores/chatStore.ts` (Zustand pattern reference)
- **Outputs:**
  - CREATED `apps/mobile/lib/stores/billingStore.ts` — Zustand slice holding `{ billingInactive: boolean; subscriptionStatus: string | null }` + `setBillingInactive(status)` + `dismiss()`.
  - CREATED `apps/mobile/components/billing/BillingInactiveModal.tsx` — RN `Modal` with title "Subscription required", body referencing `subscriptionStatus`, CTAs "Manage Subscription" (calls existing mobile `handleManageBilling` flow, see SPEC §4.0b) and "Dismiss".
  - MODIFIED `apps/mobile/lib/api.ts` — `apiClient` calls `await checkBillingGate(response)` before returning; on `BillingInactiveError`, calls `useBillingStore.getState().setBillingInactive(err.subscriptionStatus)` and rethrows.
  - MODIFIED `apps/mobile/app/_layout.tsx` — render `<BillingInactiveModal />` at root.
- **Tests (RED first):**
  - CREATED `apps/mobile/__tests__/billing/BillingInactiveModal.test.tsx` — set `setBillingInactive('canceled')`; assert modal renders with title + correct CTAs; press "Dismiss" clears state.
  - CREATED `apps/mobile/__tests__/api/billingGate.test.ts` — mock fetch returning 402 + BILLING_INACTIVE; call `apiClient`; assert `useBillingStore.getState().billingInactive === true` AND that the original `BillingInactiveError` is thrown.
  - CREATED `apps/mobile/__tests__/billing/dedup.test.ts` — two consecutive 402 responses while modal is open; assert store transitions don't double-toggle and modal is shown once.
- **Independence:** depends on T-P1.3 (shared interceptor). Parallel with T-P2.1, T-P2.2, T-P2.4..T-P2.6.
- **Reviewer focus:** dedup logic; the "Manage Subscription" CTA reuses the existing portal-open flow per SPEC §4.0b — no new `openBillingPortal` helper introduced.

### T-P2.4 — BILLING-003 mobile-test presence audit (NEW, 5-min)
- **Source spec:** §4.0b (residual)
- **Inputs (READ):** `apps/mobile/app/(tabs)/settings/index.tsx:165-175` (existing button), `apps/mobile/__tests__/settings/` (look for a test exercising the Manage-billing row)
- **Outputs:**
  - If a test already covers it: PR body documents the file:line evidence. No code changes.
  - If absent: CREATED `apps/mobile/__tests__/settings/manageSubscriptionRow.test.tsx` — render settings; find Manage-billing row; fire press; assert `handleManageBilling` is invoked and `WebBrowser.openBrowserAsync` is called.
- **Tests (RED first):** the file above (only if needed).
- **Independence:** isolated.
- **Reviewer focus:** does the existing mobile test suite cover the row? If yes, this task is a documentation no-op.

### T-P2.5 — CONTEXT-001: page text in activation context (4 readers + shared cap helper)
- **Source spec:** CONTEXT-001 (§3.8)
- **Inputs (READ):** `apps/rishi-electron/src/renderer/src/stores/chatStore.ts:71` (canonical), `apps/mobile/app/reader/[id].tsx:761`, `apps/mobile/app/reader/pdf/[id].tsx:700-704`, `apps/mobile/app/reader/mobi/[id].tsx:699`, `apps/mobile/app/reader/djvu/[id].tsx:577-581`, `packages/shared/src/voice-chat/`
- **Outputs:**
  - CREATED `packages/shared/src/voice-chat/pageTextCap.ts` — `softCapPageText(text, max=8000)` trimming at last `\n\n` or `.` before cap; appends `\n[text truncated]` if trimmed.
  - MODIFIED 4 reader files per spec §3.8 per-reader implementation — EPUB via WebView `injectJavascript` + `useRef`; MOBI via WebView `onMessage`; PDF via `pdfRef.getPageText` with indexer fallback; DJVU indexer fallback. All apply `softCapPageText` before passing into `AgentFactoryArgs.pageText`.
- **Tests (RED first):**
  - CREATED `packages/shared/src/voice-chat/pageTextCap.test.ts` — 10K-char input → ≤8000 + suffix; preserves boundary; no-op when under cap.
  - CREATED `apps/mobile/__tests__/readers/epubActivationContext.test.tsx` — simulate `onLocationChange` carrying real prose; assert `getActivationContext().pageText` contains expected text, `length > 50`, NOT a chapter label.
  - CREATED `apps/mobile/__tests__/readers/pdfActivationContext.test.tsx` — stub `getPageText` mock returning prose; assert pageText is that prose.
  - CREATED `apps/mobile/__tests__/readers/mobiActivationContext.test.tsx` — simulate `onMessage` event delivering page text; assert.
  - CREATED `apps/mobile/__tests__/readers/djvuActivationContext.test.tsx` — indexer fallback path; assert chunk `data` text is used.
- **Independence:** Cap helper test parallel with all P1.x. Reader implementation parallel with T-P2.1..T-P2.4, T-P2.6 (4 readers can be 4 sub-tasks parallelized inside this task).
- **Reviewer focus:** WebView race between `onLoad` and `injectJavascript` — guard with a ready flag; PDF fallback path is exercised; cap helper called at the boundary.

### T-P2.6 — NAVHIST-001 mobile half: consume shared machine + back-pill UI
- **Source spec:** NAVHIST-001 (§3.11)
- **Inputs (READ):** Shared machine from T-P1.6, `apps/mobile/app/reader/{[id],pdf/[id],mobi/[id],djvu/[id]}.tsx`, Reanimated docs for back-pill animation
- **Outputs:**
  - CREATED `apps/mobile/lib/machines/navigationHistory/index.ts` — re-exports from `@rishi/shared/machines/navigationHistory` plus mobile-specific `Anchor` concrete type binding.
  - CREATED `apps/mobile/components/reader/BackPill.tsx` — Reanimated-driven pill component; subscribes to navigation actor; renders when dwell-gated emission occurs.
  - MODIFIED each of the 4 reader files — instantiate the machine per-book, push on chapter/page nav, render `<BackPill />`.
- **Tests (RED first):**
  - CREATED `apps/mobile/__tests__/machines/navigationHistoryMachine.test.ts` — push, pop, depth cap, dwell-gated emission, per-book scope reset (concrete-Anchor binding).
  - CREATED `apps/mobile/__tests__/components/BackPill.test.tsx` — renders when emission fires; tap → calls `pop`; dismisses on timeout.
- **Independence:** depends on T-P1.6. Parallel with T-P2.1..T-P2.5.
- **Reviewer focus:** per-book stack isolation; Reanimated cleanup on unmount; back-press hardware key path (Android); `resumeMap` round-trips via `JSON.stringify` (no `Map`).

### T-P2.7 — VAD-001 mobile (GATED by T-P0.1 Branch A)
- **Source spec:** VAD-001 (§3.10)
- **Inputs (READ):** `packages/shared/src/voice-chat/local-vad.ts`, `apps/mobile/lib/voice-chat/media-port.ts`, T-P0.1 spike doc
- **Outputs (only if T-P0.1 = Branch A):**
  - MODIFIED `apps/mobile/package.json` — bump `react-native-worklets` to the version chosen in spike.
  - CREATED `apps/mobile/lib/voice-chat/native-vad.ts` — worklet-thread wrapper around shared `createLocalVad`, exposing `{ start(stream), stop(), onSpeechStart(cb) }`.
  - MODIFIED `apps/mobile/lib/voice-chat/service.ts` (or `buildService.ts` from T-P2.1) — wire VAD into deps.
- **Tests (RED first):**
  - CREATED `apps/mobile/__tests__/voice-chat/native-vad.test.ts` — feed fixture PCM; assert `onSpeechStart` fires within expected sample window.
  - CREATED `apps/mobile/__tests__/voice-chat/connect-window.test.ts` — simulate connect window; assert VAD signal flows into activation pipeline.
- **Outputs (if T-P0.1 = Branch B):** deferral memo `.parity-v2/VAD-001-investigation.md` (per spec §3.10 criterion 5). Task closes as deferred.
- **Independence:** isolated.
- **Reviewer focus:** worklet thread does not capture closed-over JS variables; fallback gracefully if `start()` is called before mic permission granted.

---

## Phase 3 — Electron migrations (delete local, consume shared)

**Goal:** each migration deletes electron's local copy, swaps imports to `@rishi/shared`, and ships a thin wiring test in place of the deleted suite.

**Parallelization gotcha (MAJOR-03):** every DRY task in this phase touches `apps/rishi-electron/src/renderer/src/services/index.ts` (the central wiring file). To prevent merge conflicts, T-P3.1/T-P3.2/T-P3.3/T-P3.5 each leave a comment marker in `services/index.ts` (e.g. `// PARITY-V2: VOICE-CHAT-MIGRATED — wire @rishi/shared/voice-chat here`). The final T-P3.6 task collects all markers and resolves them in a single PR after the deletions land. The other DRY work (deleting the local directory, adding factory-wiring tests in the deleted dir's replacement spot) is independent and can run in parallel.

### T-P3.1 — DRY-001: voice-chat migration
- **Source spec:** DRY-001 (§3.3); closes R-001, D-011
- **Inputs (READ):** `apps/rishi-electron/src/renderer/src/services/voice-chat/` (all files), `apps/rishi-electron/src/renderer/src/services/index.ts`, `apps/rishi-electron/src/utils/sentry.ts`, all electron voice-chat test files
- **Outputs:**
  - DELETED `apps/rishi-electron/src/renderer/src/services/voice-chat/` (entire directory). **(MINOR-03 / REVIEW-02 MINOR-NEW-01)** Verified `ls` file inventory: `activation-program.ts`, `emitter.test.ts`, `emitter.ts`, `errors.test.ts`, `errors.ts`, `index.ts`, `key-cache.test.ts`, `key-cache.ts`, `local-vad.test.ts`, `local-vad.ts`, `machine.coverage.test.ts`, `machine.test.ts`, `machine.ts`, `service.test.ts`, `service.ts`, `types.test.ts`, `types.ts` — **17 files total** (9 source + 8 test). The reviewer gate is "17 files deleted" plus deletion-audit pairing each `*.test.ts` to its shared equivalent.
  - MODIFIED `apps/rishi-electron/src/renderer/src/services/index.ts` — **leaves a comment marker** for T-P3.6 to resolve (does NOT swap the import path in this task to avoid merge conflicts with T-P3.2..T-P3.5).
  - CREATED `apps/rishi-electron/src/renderer/src/services/__tests__/voiceChatFactoryWiring.test.ts` — asserts `services/index.ts` (post-T-P3.6) supplies a `captureError` function and correct IPC shape (including the existing `reportRealtimeUsage` wiring per SPEC §4.0a).
- **Tests (RED first):** the factory wiring test. **Deletion-audit:** each deleted electron test must map to a shared equivalent. Coder produces a table in PR body.
- **Independence:** parallel with T-P3.2, T-P3.3, T-P3.4, T-P3.5 (no `services/index.ts` content change yet). Depends only on shared voice-chat being green.
- **Reviewer focus:** **DELETED tests** are all covered by shared. Comment marker is unambiguous. The wiring test is currently red (until T-P3.6 lands).

### T-P3.2 — DRY-002: TTS migration
- **Source spec:** DRY-002 (§3.4); closes R-002, R-009, D-010
- **Inputs (READ):** `apps/rishi-electron/src/renderer/src/services/tts/{service.ts, cache.ts, types.ts:56-62, …}`, `apps/rishi-electron/src/renderer/src/services/index.ts`
- **Outputs:**
  - DELETED `apps/rishi-electron/src/renderer/src/services/tts/` (entire directory).
  - MODIFIED `apps/rishi-electron/src/renderer/src/services/index.ts` — **leaves a comment marker** for T-P3.6.
  - CREATED `apps/rishi-electron/src/renderer/src/services/__tests__/ttsFactoryWiring.test.ts` — asserts `linkOrCopyFile` is supplied and `createTtsService` is called with correct deps (post-T-P3.6).
- **Tests (RED first):** factory wiring test. Audit electron's TTS test files vs shared.
- **Independence:** depends on T-P1.4. Parallel with T-P3.1, T-P3.3..T-P3.5.
- **Reviewer focus:** **DELETED tests** are all covered by shared; cache directory size sanity check noted in PR body.

### T-P3.3 — DRY-003: book-import migration (with adapter)
- **Source spec:** DRY-003 (§3.5); closes R-003, D-013, EBUG-003
- **Inputs (READ):** `apps/rishi-electron/src/renderer/src/services/book-import/{service.ts,importer.ts,indexer.ts,dispatch.ts,emitter.ts,types.ts,scanner-adapter.ts}`, `packages/shared/src/book-import/{service.ts,types.ts}`
- **Outputs:**
  - CREATED `apps/rishi-electron/src/renderer/src/services/book-import/electron-adapter.ts` — maps electron's `BookStoreIpc`/`FormatsIpc`/`FsIpc`/`FileSyncIpc` (with `BookId=number`) onto shared's generic ports.
  - CREATED `apps/rishi-electron/src/renderer/src/services/book-import/electron-adapter.test.ts` — adapter tests.
  - MODIFIED `apps/rishi-electron/src/renderer/src/services/book-import/index.ts` — re-export `BookFormat` etc. from `@rishi/shared/book-import` + the adapter.
  - MODIFIED `apps/rishi-electron/src/renderer/src/services/index.ts` — **leaves a comment marker** for T-P3.6.
  - DELETED: `service.ts`, `importer.ts`, `indexer.ts`, `dispatch.ts`, `emitter.ts`, `types.ts` (non-scanner portions) + tests.
  - KEPT: `scanner-adapter.ts`, `scanner-adapter.test.ts`.
- **Tests (RED first):** the adapter test.
- **Independence:** depends on T-P1.5. Parallel with T-P3.1, T-P3.2, T-P3.4, T-P3.5.
- **Reviewer focus:** **DELETED tests** audit; `BookId=number` parametric instantiation; DJVU error path explicit.

### T-P3.4 — DRY-004: lift `renderRealtimeInstructions` helpers
- **Source spec:** DRY-004 (§3.6); closes R-004, D-012, EBUG-002, T-005, T-006
- **Inputs (READ):** `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-158`, `packages/shared/src/voice-chat/build-realtime-agent.ts`
- **Outputs:**
  - MODIFIED `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts` — delete the three inline helpers; import `renderRealtimeInstructions` from `@rishi/shared/voice-chat/build-realtime-agent`. **No `services/index.ts` edits in this task** — DRY-004 touches `modules/buildRealtimeAgent.ts` only.
  - MODIFIED or DELETED `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts`.
- **Tests (RED first):** CREATED `packages/shared/src/voice-chat/promptParity.test.ts` — fixed-fixture snapshot.
- **Independence:** parallel with T-P3.1..T-P3.3, T-P3.5. **Does not touch `services/index.ts` and so is unaffected by T-P3.6 sequencing.**
- **Reviewer focus:** `grep -rn "renderOutlineSection\|renderActiveParagraphSection\|renderVisualSection" apps/rishi-electron/src` → zero matches.

### T-P3.5 — NAVHIST-001 electron migration (consumes T-P1.6 shared machine)
- **Source spec:** NAVHIST-001 (§3.11); closes R-007 as a byproduct (per orchestrator B)
- **Inputs (READ):** `apps/rishi-electron/src/renderer/src/machines/navigationHistory/` (all files), shared output from T-P1.6
- **Outputs:**
  - MODIFIED `apps/rishi-electron/src/renderer/src/machines/navigationHistory/` — replace `navigationHistoryMachine.ts`, `pageKey.ts`, `types.ts` with thin re-exports from `@rishi/shared/machines/navigationHistory`, binding electron's concrete `AnchorPoint`. If electron's local consumers use a `Map` for `resumeMap`, add a tiny adapter at the consumption boundary that converts `Record` → `Map` (and back) — the shared canonical type stays `Record` per MINOR-05.
  - MODIFIED `apps/rishi-electron/src/renderer/src/services/index.ts` — **leaves a comment marker** for T-P3.6 (only if any wiring change is needed).
- **Tests (RED first):** electron tests refactored to test concrete-Anchor binding. NEW: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/electronBinding.test.ts`.
- **Independence:** depends on T-P1.6. Parallel with T-P3.1..T-P3.4.
- **Reviewer focus:** electron behavior unchanged; R-007 documented as closed in PR body; `Record` ⇄ `Map` adapter (if used) is one-line and tested.

### T-P3.6 — NEW: electron `services/index.ts` wiring merge (sequenced after T-P3.1..T-P3.5)
- **Source spec:** DRY-001/002/003/005 integration site (§3.3..§3.5, §3.11)
- **Rationale (MAJOR-03):** T-P3.1, T-P3.2, T-P3.3, T-P3.5 each modify `apps/rishi-electron/src/renderer/src/services/index.ts` by leaving a `// PARITY-V2: <ITEM>-MIGRATED` comment marker. Doing the import-swap edits in parallel would race and conflict. T-P3.6 collects all markers in one PR.
- **Inputs (READ):** post-merge `apps/rishi-electron/src/renderer/src/services/index.ts` (with all comment markers from T-P3.1..T-P3.3, T-P3.5), shared module exports
- **Outputs:**
  - MODIFIED `apps/rishi-electron/src/renderer/src/services/index.ts`:
    - Replace local imports with `@rishi/shared/voice-chat`, `@rishi/shared/tts`, `@rishi/shared/book-import` (via the adapter), `@rishi/shared/machines/navigationHistory` (via thin binding).
    - Supply `captureError: sentryCaptureError` from the existing `@/utils/sentry` import to the voice-chat factory.
    - Supply `linkOrCopyFile` IPC channel to the TTS factory.
    - Supply the book-import adapter factory output.
    - Remove all `// PARITY-V2: …` comment markers.
- **Tests (RED first):** The factory wiring tests authored in T-P3.1, T-P3.2, T-P3.3 transition from red → green when this task lands. CREATED `apps/rishi-electron/src/renderer/src/services/__tests__/indexWiring.test.ts` — single end-to-end assertion that all four factories receive their expected deps.
- **Independence:** sequential after T-P3.1..T-P3.3 + T-P3.5 + T-P1.6. Parallel with T-P3.4 (which never touches `services/index.ts`).
- **Reviewer focus:** zero comment markers remain; `grep -r "services/voice-chat\|services/tts" apps/rishi-electron/src` returns no local-path imports; all four factory-wiring tests pass green.

---

## Phase 4 — (REMOVED post-REVIEW-01)

EBUG-FIX-001 and electron BILLING-001 are closed on `main`. No Phase 4 worker tasks this round.

---

## Phase 5 — Parity tests

### T-P5.1 — DRY-005 chunk-ID cross-platform parity test
- **Source spec:** DRY-005 (§3.7); closes T-004, G-010
- **Inputs (READ):** T-P0.2 spike doc, `packages/shared/src/book-import/indexer.ts`, electron adapter from T-P3.3
- **Outputs:**
  - CREATED `packages/shared/src/book-import/chunkIdParity.test.ts` — fixture: 2-page minimal raw-text input; calls shared indexer; calls same input through the post-T-P3.3 adapter path; asserts deep-equal `{ id, pageNumber, data }`. **If T-P0.2 = "test.failing":** ship as `test.failing` with TODO comment + linked follow-up alignment issue.
- **Tests (RED first):** the test file itself IS the deliverable.
- **Independence:** depends on T-P3.3 (adapter), T-P0.2 (decision).
- **Reviewer focus:** if `test.failing`, follow-up issue link is in the comment; fixture is deterministic.

### T-P5.2 — Prompt parity test (electron post-DRY-004 vs shared)
- **Source spec:** DRY-004 (§3.6) — covered by T-P3.4's `promptParity.test.ts`. **No additional task needed.**
- **Status:** SUBSUMED by T-P3.4.

---

## Summary — Task Counts

| Phase | Tasks |
|---|---|
| Phase 0 — Spikes | 3 (T-P0.0, T-P0.1, T-P0.2) |
| Phase 1 — Shared API | 4 (T-P1.3, T-P1.4, T-P1.5, T-P1.6) |
| Phase 2 — Mobile | 7 (T-P2.1..T-P2.7) |
| Phase 3 — Electron migrations | 6 (T-P3.1..T-P3.6) |
| Phase 4 — Worker / cross-cutting | 0 (removed) |
| Phase 5 — Parity tests | 1 (T-P5.1; T-P5.2 subsumed) |
| **Total** | **21** |

(Pre-revision total was 26. Net: −9 removed, +4 added = −5.)

---

## Parallelization Batches

| Batch | Tasks | Reasoning |
|---|---|---|
| B-0 (sequential) | T-P0.0 | Preflight for mobile test runner. |
| B-1 (parallel × 2) | T-P0.1, T-P0.2 | Independent spikes; different domains. |
| B-2 (parallel × 4) | T-P1.3, T-P1.4, T-P1.5, T-P1.6 | All additive shared exports in different files. |
| B-3a (parallel × 5) | T-P2.1, T-P2.2, T-P2.3, T-P2.4, T-P2.5 | Different mobile surfaces. T-P2.3 depends on T-P1.3. |
| B-3b (sequential after T-P1.6) | T-P2.6 | Depends on shared machine. |
| B-3c (gated) | T-P2.7 | Only if T-P0.1 Branch A. |
| B-4 (parallel × 5) | T-P3.1, T-P3.2, T-P3.3, T-P3.4, T-P3.5 | Each leaves a comment marker in `services/index.ts` (except T-P3.4 which doesn't touch it). Deletions and adapter additions are independent. |
| B-5 (sequential after B-4) | T-P3.6 | **Bottleneck:** collects all `services/index.ts` markers in one PR (MAJOR-03 fix). |
| B-6 | T-P5.1 | After T-P3.3 (adapter). |

**Critical path:** B-0 → B-1 → B-2 → (B-3a ∥ B-3b ∥ B-3c) ⤴ → B-4 → B-5 → B-6.

The `services/index.ts` merge is now the explicit serialization point at B-5, eliminating the multi-coder race.

---

## Risk Analysis — Top 5 with Mitigations

### R1. DRY migrations touching deleted electron tests
**Likelihood: High. Impact: Medium.** Electron has multiple voice-chat (8), TTS (6), and book-import (5) test files. Some may assert local-only behavior not covered by shared.
**Mitigation:**
- Each DRY task (T-P3.1, T-P3.2, T-P3.3) requires the coder to `git diff --stat` the deleted-vs-shared file pairs and produce a deletion-audit table in the PR body.
- The reviewer MUST verify each deleted assertion has a shared equivalent OR a justified non-port.
- Factory-wiring tests (`voiceChatFactoryWiring.test.ts`, `ttsFactoryWiring.test.ts`, `electron-adapter.test.ts`, `indexWiring.test.ts`) provide net-new electron-only coverage.

### R2. Mobile `react-native-worklets` upgrade cascading to Reanimated
**Likelihood: Medium. Impact: High.** Worklets ↔ Reanimated peer-dep coupling is fragile.
**Mitigation:**
- T-P0.1 spike produces an exact-version compatibility matrix.
- Per orchestrator constraint C, VAD-001 is DEFERRED without scope expansion if compat fails.

### R3. `services/index.ts` merge conflicts (MAJOR-03)
**Likelihood: Medium. Impact: Medium.** Phase-3 DRY tasks all touch the central electron wiring file.
**Mitigation:** T-P3.6 (NEW) collects all `// PARITY-V2: <ITEM>-MIGRATED` markers and resolves them in a single sequenced PR. T-P3.1..T-P3.3 and T-P3.5 only insert markers; they do NOT swap imports.

### R4. `packages/shared` circular dependencies on new exports
**Likelihood: Low. Impact: Medium.**
**Mitigation:**
- Each P1 task lists exact files written. Reviewer cross-checks existing barrels for circular re-exports.
- `pnpm --filter @rishi/shared test` runs after each P1 merge; vitest catches require-time cycles loudly.

### R5. Test runner config divergence (mobile jest vs everyone else's vitest)
**Likelihood: Medium. Impact: Medium.**
**Mitigation:**
- T-P0.0 adds a stable mobile `test` script.
- Shared tests do NOT import mobile code.
- Mobile tests use `jest.useFakeTimers()`; shared uses `vi.useFakeTimers()`. Both verified independently.

---

## Quality Gates (per task)

Each task must, before merging:
1. **Red phase:** the test file listed under "Tests" exists and fails on `main` (or with the implementation reverted).
2. **Green phase:** implementation lands; test passes; full surface test suite still green.
3. **Behavior parity check:** for any behavior-touching change, the PR body cites the canonical electron file:line (per SPEC §2.1) or the relevant §4.0x closed-implementation pointer.
4. **Deletion audit (Phase 3 only):** each deleted electron test is mapped to its shared equivalent OR justified as not-ported.
5. **Documentation:** new shared exports appear in the relevant `index.ts` barrel and `packages/shared/package.json` `exports` map.
6. **No regression:** monorepo `pnpm test` (or per-surface runs for tasks scoped to one surface) green; no new failures.

---

**End of PLAN.md**
