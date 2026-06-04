# SPEC.md — Mobile/Electron Parity v2 + DRY Rearchitecture

**Spec date:** 2026-06-04
**Worktree:** `mobile-electron-parity-v2`
**Authority for behavior:** electron (`apps/rishi-electron`) — except where superseded by shared (`packages/shared`)
**Mandate:** Test-driven (red → green → refactor). All in-scope items get failing tests authored first.

---

## 1. Goal & Non-Goals

### 1.1 Goal

Eliminate behavioral drift and code duplication between `apps/rishi-electron` and `apps/mobile` and establish `packages/shared` as the single source of truth for cross-platform service logic. After this round:

- Realtime usage reporting (`POST /api/billing/realtime-usage`) is verified end-to-end on mobile (electron coverage is pre-existing) — see §4 for the closed BILLING-001/003 and the EBUG-001 idempotency items.
- Both clients surface a "Subscription required" UI on `402 BILLING_INACTIVE` instead of raw network errors.
- Electron's voice-chat, TTS, book-import, and realtime-prompt logic come from `@rishi/shared` (single source of truth — no silent drift).
- Mobile's four readers pass real rendered page text into the realtime agent context.
- Mobile gains a local VAD (parity with electron's connect-window pre-roll).
- Mobile gains navigation history (back-pill UX).
- Live voice-chat service is wired into the mobile root provider (closing the `setChatVoicePort` gap).

### 1.2 Non-Goals

- Building P2P book-sharing on mobile (deferred — see §4).
- Implementing Skia-based page-curl on mobile (deferred — see §4).
- Adding the ready-chime / thinking-sound polish on mobile (deferred — P3, see §4).
- Modifying the worker (no in-scope worker changes this round; EBUG-001 idempotency is already closed — see §4).
- Refactoring sync, P2P, or the OAuth deep-link plumbing (already stable).
- Migrating to TanStack AI realtime (parked — see `reference_tanstack_ai_experiment.md`).
- Bumping `react-native-worklets` to a major version that breaks Reanimated (use the minimum compatible version per VAD-001).

---

## 2. Authority Model & DRY Policy

### 2.1 Behavioral authority

For every in-scope behavior, electron is canonical unless the shared module already supersedes electron (some surfaces moved in parity-v1 and electron never caught up — `D-010`/`D-011`/`D-012`/`D-013`). Each in-scope item below cites the canonical reference at file:line.

### 2.2 DRY policy (overrides the broad `feedback_electron_only.md` rule)

Where electron has a local copy of logic that already exists in `packages/shared`, **electron is refactored to consume shared** in this round. The migration direction is:

1. Make the shared API forward-compatible (add optional ports, missing fields).
2. Electron swaps its imports to `@rishi/shared/<module>`.
3. Delete the electron local copy.
4. Run tests (shared + electron + mobile) green.

`feedback_electron_only.md` is honored everywhere this spec does **not** explicitly call out a DRY-### item.

### 2.3 What stays electron-side (do not lift)

- Scanner adapter (`apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.ts`, `DiscoveryEvent`, `ScannerPort`).
- IPC bindings (`window.electron.*`, `window.api.*`).
- The `Sentry` import (used at the wiring site to fill the optional `captureError` port).
- `@openai/agents/realtime` SDK wiring (electron-only — mobile uses raw WebRTC).
- `OpenAIRealtimeWebRTC` factory and `RtcTransportLike` wrapper.
- P2P sharing actors (`actors/sharing/`, `machines/sessionMachine.ts`, `@rishi/sharing-protocol`).
- `apps/rishi-electron/src/renderer/src/machines/navigationHistory/` stays electron-local for now — `NAVHIST-001` introduces an independent mobile implementation rather than lifting electron's verbatim (see §3.11 risk note).

### 2.4 Shared lift policy

When new exports are added to shared:

1. Add a barrel entry in `packages/shared/src/<module>/index.ts`.
2. Add an entry to the `exports` map in `packages/shared/package.json`.
3. Add the type at the package boundary if consumed via `import type`.

### 2.5 TDD mandate

Tests are written before implementation (red → green → refactor) per `feedback_tdd.md`. Each in-scope item lists tests to write first under its acceptance criteria.

### 2.6 Non-breaking shared changes

All additions to shared interfaces (`TtsIpcChannels.linkOrCopyFile`, billing error/interceptor exports, `navigationHistoryMachine` exports) must be additive and optional where existing callers exist. Otherwise mobile will compile-fail before electron is migrated. Required-vs-optional decisions are spelled out per item.

### 2.7 Secrets / env unchanged

No new env vars are introduced. `STRIPE_*`, `OPENAI_API_KEY`, `BETTER_AUTH_SECRET` remain unchanged. The worker's trusted origins (`rishi-electron://`, `rishimobile://`) are unchanged.

---

## 3. In-Scope Items (11)

Each item: **behavior contract** → **canonical reference** → **acceptance criteria** → **files** → **risk**.

> **Revision note (2026-06-04):** the original draft listed 13 items. After REVIEW-01, three items were confirmed already implemented on `main` (BILLING-001 realtime usage reporting on both clients, BILLING-003 portal link on both clients, EBUG-FIX-001 idempotency on the worker) and have been moved to §4 Deferred / Done with implementation pointers. They are replaced by a single thin BILLING-AUDIT-001 verification task (§3.1).

---

### 3.1 BILLING-AUDIT-001 — Mobile Realtime-Usage Integration Test

**Closes:** T-003 (residual verification only — implementation closed via §4)

#### Behavior contract

Realtime usage reporting (`POST /api/billing/realtime-usage`) is already implemented on both clients (see §4 BILLING-001-CLOSED). The remaining gap is **test coverage on mobile**: confirm via an integration test that `reportRealtimeUsage` is invoked during a simulated voice-chat session lifecycle (`response.done` → session `close()` → POST to the worker).

If equivalent electron coverage is missing, flag it; do not author it as part of this round (electron's existing test suite is presumed to cover this path — coder must `grep -rn "reportRealtimeUsage" apps/rishi-electron/src` to confirm).

#### Canonical references

- Endpoint body shape: inline in `workers/worker/src/index.ts:242-252`.
- Mobile event site (already implemented): `apps/mobile/lib/voice-chat/realtime-session.ts:280-298` (`case 'response.done'` extracts `input_token_details`/`output_token_details`, calls `usage.add(...)`).
- Mobile flush site: `apps/mobile/lib/voice-chat/realtime-session.ts:364-374` (`close()` calls `usage.flush()` then `void reportRealtimeUsage(apiClient, total)`).
- Shared accumulator + client: `packages/shared/src/billing/realtime-usage-accumulator.ts`, `packages/shared/src/billing/realtime-usage-client.ts`.
- Electron service import: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts:14` (`import { reportRealtimeUsage } from '@rishi/shared/billing/realtime-usage-client'`).
- Electron wiring: `apps/rishi-electron/src/renderer/src/services/index.ts:262` (`billing: { apiFetch: workerFetch }`).

#### Mobile implementation

No production code changes. One new test file:

- `apps/mobile/__tests__/voice-chat/billingReport.integration.test.ts` — drives a fake `RealtimeSession` lifecycle:
  1. Construct the mobile session factory with a mocked `apiClient`.
  2. Inject a synthetic `response.done` event with `usage: { input_token_details: {...}, output_token_details: {...} }` token counts.
  3. Call `session.close()`.
  4. Assert `apiClient` was invoked exactly once with `POST /api/billing/realtime-usage` and the body shape matches `workers/worker/src/index.ts:242-252` (sum of audio/text in/out tokens).

#### Electron audit

- `grep -rn "reportRealtimeUsage" apps/rishi-electron/src` — confirm at least one test asserts the wiring. If absent, document the gap in the PR body and open a follow-up issue (do NOT author electron tests in this round).

#### Acceptance criteria

1. Mobile integration test exists and passes green.
2. PR body cites the file:line evidence from `apps/mobile/lib/voice-chat/realtime-session.ts:280-298` and `:364-374`.
3. Electron audit grep result documented in PR body (pass or follow-up issue link).
4. Zero changes to `packages/shared`, `apps/mobile/lib/voice-chat/`, or `apps/rishi-electron/src` production code.

#### Files

- **CREATED:** `apps/mobile/__tests__/voice-chat/billingReport.integration.test.ts`

#### Risk

**Low.** Test-only; no production code modified.

---

### 3.2 BILLING-002 — `402 BILLING_INACTIVE` Handling

**Closes:** D-003, T-001

#### Behavior contract

Any HTTP response with status `402` and body `{ code: 'BILLING_INACTIVE' }` MUST be intercepted before reaching the calling UI. The interceptor throws a typed `BillingInactiveError` carrying `subscriptionStatus`. The app's root surfaces a modal: title "Subscription required", body referencing the user's subscription status, primary CTA "Manage Subscription" (invokes BILLING-003 portal-open), secondary "Dismiss".

The modal MUST be shown once per surfaced error — repeated 402 throws while the modal is open should be deduplicated by the slice holding `billingInactive` state.

#### Canonical reference

- Worker response shape: `workers/worker/src/billing/sub-gate.ts:57` returns `{ error: string, code: "BILLING_INACTIVE", subscriptionStatus: string | null }`
- Affected endpoints: `workers/worker/src/index.ts:263,314,347,383` (`/api/audio/speech`, `/api/realtime/client_secrets`, `/api/text/completions`, `/api/embed`)

#### Shared API additions

**`packages/shared/src/billing/errors.ts`** — NEW:

```typescript
export class BillingInactiveError extends Error {
  readonly code = 'BILLING_INACTIVE' as const
  readonly subscriptionStatus: string | null
  constructor(subscriptionStatus: string | null)
}

export function isBillingInactiveResponse(
  status: number,
  body: unknown
): body is { code: 'BILLING_INACTIVE'; subscriptionStatus: string | null }
```

**`packages/shared/src/billing/interceptor.ts`** — NEW:

```typescript
// Throws BillingInactiveError if response matches; returns normally otherwise.
// Safe to call on every non-2xx response.
export async function checkBillingGate(response: Response): Promise<void>
```

#### Mobile implementation

- `apps/mobile/lib/api.ts` — `apiClient` calls `await checkBillingGate(response)` before returning on any non-OK path. The `BillingInactiveError` propagates to callers.
- `apps/mobile/components/billing/BillingInactiveModal.tsx` — NEW. Uses `Modal` from `react-native`. Reads from a Zustand slice (new field on existing `prefsStore` or new `billingStore`).
- `apps/mobile/lib/stores/billingStore.ts` — NEW. Holds `{ billingInactive: boolean; subscriptionStatus: string | null }` with `setBillingInactive(status)` and `dismiss()` actions.
- `apps/mobile/app/_layout.tsx` — render `<BillingInactiveModal />` at root.
- `apps/mobile/lib/api.ts` — on catching `BillingInactiveError`, call `useBillingStore.getState().setBillingInactive(err.subscriptionStatus)`.

#### Electron implementation

- `apps/rishi-electron/src/renderer/src/lib/api.ts` — same `checkBillingGate` call.
- `apps/rishi-electron/src/renderer/src/components/billing/BillingInactiveModal.tsx` — NEW. Radix-style dialog.
- `apps/rishi-electron/src/renderer/src/stores/billingStore.ts` — NEW or extend existing.
- Top-level layout renders the modal.

#### Acceptance criteria

1. **Shared interceptor:** `packages/shared/__tests__/billing/interceptor.test.ts` — three cases: (a) 402 + `BILLING_INACTIVE` → throws `BillingInactiveError`, (b) 200 → no throw, (c) 402 + arbitrary body (no `BILLING_INACTIVE`) → no throw (passes through to caller).
2. **Error class:** Same file — `BillingInactiveError` instances pass `instanceof BillingInactiveError`, `err.code === 'BILLING_INACTIVE'`, `err.subscriptionStatus` is preserved.
3. **Mobile modal:** `apps/mobile/__tests__/billing/BillingInactiveModal.test.tsx` — triggers `setBillingInactive('canceled')`, asserts modal renders with correct title and CTA.
4. **Mobile API integration:** `apps/mobile/__tests__/api/billingGate.test.ts` — mocks fetch returning 402 + BILLING_INACTIVE, calls `apiClient`, asserts `useBillingStore.getState().billingInactive === true`.
5. **Electron:** equivalent modal + API integration tests.

#### Files

- **CREATED:**
  - `packages/shared/src/billing/errors.ts`
  - `packages/shared/src/billing/interceptor.ts`
  - `packages/shared/src/billing/index.ts` (if not present; barrel)
  - `packages/shared/__tests__/billing/interceptor.test.ts`
  - `apps/mobile/lib/stores/billingStore.ts`
  - `apps/mobile/components/billing/BillingInactiveModal.tsx`
  - `apps/mobile/__tests__/billing/BillingInactiveModal.test.tsx`
  - `apps/mobile/__tests__/api/billingGate.test.ts`
  - `apps/rishi-electron/src/renderer/src/stores/billingStore.ts` (or extend)
  - `apps/rishi-electron/src/renderer/src/components/billing/BillingInactiveModal.tsx`
  - electron equivalents of the test files
- **MODIFIED:**
  - `apps/mobile/lib/api.ts`
  - `apps/mobile/app/_layout.tsx`
  - `apps/rishi-electron/src/renderer/src/lib/api.ts`
  - electron root layout
  - `packages/shared/package.json` (exports map: `./billing/errors`, `./billing/interceptor`)

#### Risk

**Low.** Both clients already have an `apiClient` wrapper — the interceptor is a single insertion point. Modal styling is per-platform but conventional.

---

### 3.3 DRY-001 — Lift Voice-Chat Service to Shared

**Closes:** R-001, D-011

#### Behavior contract

Electron's `apps/rishi-electron/src/renderer/src/services/voice-chat/` directory is deleted in its entirety (8 source files + 6 test files). Electron's `services/index.ts` imports `createVoiceChatService`, `createLocalVad`, and voice-chat types from `@rishi/shared/voice-chat`. The hardcoded `import { captureError } from '@/utils/sentry'` at electron's `service.ts:9` becomes the optional `deps.captureError` port already present on shared's `VoiceChatServiceDeps`. The wiring site supplies it.

#### Canonical reference

- Shared service: `packages/shared/src/voice-chat/service.ts`
- Electron service (to delete): `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts:9`
- Mobile already consumes shared: `apps/mobile/lib/voice-chat/service.ts` (existing pattern is the template)

#### Migration sequence

1. Verify shared's `VoiceChatServiceDeps.captureError` is optional and called safely. (Already the case per `packages/shared/src/voice-chat/service.ts`.)
2. In `apps/rishi-electron/src/renderer/src/services/index.ts`, switch the import path from `./voice-chat` to `@rishi/shared/voice-chat`. Supply `captureError: sentryCaptureError` from the existing Sentry import at the wiring site.
3. Run electron tests — confirm green.
4. Delete `apps/rishi-electron/src/renderer/src/services/voice-chat/` (all files).
5. Run all test suites (shared + mobile + electron) — confirm green.

#### Tests

Shared already has equivalent coverage (`emitter.test.ts`, `errors.test.ts`, `key-cache.test.ts`, `machine.coverage.test.ts`, `machine.test.ts`, `service.test.ts`, `types.test.ts`, `local-vad.test.ts`). Electron's parallel tests are deleted.

A new electron-only test, `apps/rishi-electron/src/renderer/src/services/__tests__/voiceChatFactoryWiring.test.ts`, asserts that the electron-side wiring (constructor call in `services/index.ts`) supplies a `captureError` function and the correct IPC shape.

#### Acceptance criteria

1. `grep -r "services/voice-chat" apps/rishi-electron/src` returns ONLY the import in `services/index.ts` (renamed to point at shared) — no other references.
2. `ls apps/rishi-electron/src/renderer/src/services/voice-chat/` returns "No such file or directory".
3. `pnpm test --filter rishi-electron` passes green.
4. `pnpm test --filter @rishi/shared` passes green.
5. `apps/rishi-electron/src/renderer/src/services/__tests__/voiceChatFactoryWiring.test.ts` exists and asserts wiring shape.

#### Files

- **DELETED:** `apps/rishi-electron/src/renderer/src/services/voice-chat/` (entire directory, 17 files: 9 source + 8 test)
- **MODIFIED:** `apps/rishi-electron/src/renderer/src/services/index.ts` (import path swap, supply `captureError`)
- **CREATED:** `apps/rishi-electron/src/renderer/src/services/__tests__/voiceChatFactoryWiring.test.ts`

#### Risk

**Medium.** Electron has 6 voice-chat test files. If any test asserts implementation details only present in the local copy (not in shared), it must be either ported or removed with justification. The coder must diff the test files before deletion.

---

### 3.4 DRY-002 — Lift TTS Service to Shared

**Closes:** R-002, R-009, D-010

#### Behavior contract

Electron's `apps/rishi-electron/src/renderer/src/services/tts/` is deleted (14 source + test files). Electron's `services/index.ts` imports `createTtsService` from `@rishi/shared/tts`. The `linkOrCopyFile` hardlink optimization is preserved by adding it to the shared `TtsIpcChannels` as an optional field. The shared `cache.ts` prefers `linkOrCopyFile` when present.

#### Canonical references

- Shared service: `packages/shared/src/tts/service.ts`
- Shared types: `packages/shared/src/tts/types.ts` (currently missing `linkOrCopyFile`)
- Electron `linkOrCopyFile`: `apps/rishi-electron/src/renderer/src/services/tts/types.ts:56-62`

#### Pre-migration: forward-compatible shared API

**`packages/shared/src/tts/types.ts`** — add to `TtsIpcChannels`:

```typescript
/**
 * Hardlink src→dest so both names share one inode (zero extra disk).
 * Falls back to copyFile on EXDEV (cross-volume). Optional: mobile
 * does not implement it; electron's cache uses it for the texthash mirror.
 */
linkOrCopyFile?: (src: string, dest: string) => Promise<void>
```

**`packages/shared/src/tts/cache.ts`** — where it currently calls `ipc.copyFile(src, dest)` to create the texthash mirror, change to:

```typescript
const linkOrCopy = ipc.linkOrCopyFile ?? ipc.copyFile
await linkOrCopy(src, dest)
```

**Investigation correction:** RESEARCH.md R-002 claims the shared `service.ts` uses an injectable `makeAudioUri` port; the architect verification found `makeAudioUri` is defined in `TtsServiceDeps` but the shared `service.ts` still calls `URL.createObjectURL` inline. The coder MUST verify and, if confirmed, change the inline call to `deps.makeAudioUri?.(blob) ?? URL.createObjectURL(blob)` as part of this migration. Both clients then get the same code path.

#### Migration sequence

1. Apply the additive shared API changes above.
2. Verify shared tests pass.
3. Electron `services/index.ts` swaps the import. Supplies the existing `linkOrCopyFile` IPC channel as-is.
4. Delete electron's `services/tts/` directory.
5. Run all suites green.

#### Acceptance criteria

1. `grep -r "services/tts" apps/rishi-electron/src` returns only `services/index.ts` import (renamed).
2. `ls apps/rishi-electron/src/renderer/src/services/tts/` reports missing.
3. New cache test: `packages/shared/src/tts/cache.test.ts` adds a case where both `linkOrCopyFile` and `copyFile` are provided, asserts `linkOrCopyFile` is preferred.
4. Electron TTS cache directory size (verified manually post-migration; not automated) does not double when texthash mirror is created.
5. `pnpm test` green across shared + electron.

#### Files

- **MODIFIED:**
  - `packages/shared/src/tts/types.ts` (+ optional `linkOrCopyFile`)
  - `packages/shared/src/tts/cache.ts` (prefer `linkOrCopyFile`)
  - `packages/shared/src/tts/service.ts` (use `deps.makeAudioUri` when provided — investigation-gated)
  - `packages/shared/src/tts/cache.test.ts` (add linkOrCopyFile case)
  - `apps/rishi-electron/src/renderer/src/services/index.ts` (import swap)
- **DELETED:** `apps/rishi-electron/src/renderer/src/services/tts/` (entire directory)

#### Risk

**Medium.** Same as DRY-001 — electron's test files must be diff'd against shared's before deletion to ensure no electron-only coverage is lost.

---

### 3.5 DRY-003 — Lift Book-Import Service to Shared (with adapter)

**Closes:** R-003, D-013, EBUG-003

#### Behavior contract

Electron consumes `createBookImportService` from `@rishi/shared/book-import` via a thin adapter that maps electron's IPC port shapes (`BookStoreIpc`, `FormatsIpc`, `FsIpc`, `FileSyncIpc`) to shared's structural ports (`DbPort`, `FsPort`, `FormatsPort`, `UploadPort`, `EmbedPort`, `CoverPort`). The electron-only `ScannerPort` / `DiscoveryEvent` machinery stays electron-side as a wrapper extending the shared service.

DJVU is supported in the unified `BookFormat` (closes EBUG-003).

#### Canonical references

- Shared service: `packages/shared/src/book-import/service.ts`
- Shared types: `packages/shared/src/book-import/types.ts:20` (`'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'`)
- Electron service to delete: `apps/rishi-electron/src/renderer/src/services/book-import/service.ts`
- Electron scanner to keep: `apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.ts`

#### Why an adapter (correction to brief)

**The brief suggested a clean import swap. Verification shows electron's `BookImportServiceDeps` uses different port shapes than shared's.** Electron uses `BookStoreIpc`/`FormatsIpc`/`FsIpc`/`FileSyncIpc` with non-generic `BookId = number`; shared uses generic `DbPort<BookId>`/`FormatsPort`/`FsPort`/`UploadPort` with parametric `BookId`. The adapter pattern lets electron preserve its IPC layer while consuming shared logic underneath.

#### Migration sequence

1. Confirm shared `BookImportServiceDeps` accepts a generic `BookId = number`; ensure exports are stable for the adapter.
2. Create `apps/rishi-electron/src/renderer/src/services/book-import/electron-adapter.ts`:
   - Takes existing electron deps (`BookStoreIpc`, `FormatsIpc`, `FsIpc`, `FileSyncIpc`, `RagService`, scanner, embed function, config).
   - Maps them to shared `BookImportServiceDeps<number, Book, BookInsertable>` and constructs `createBookImportService` from shared.
   - Wraps the shared service with `startDiscovery` / `cancelDiscovery` / `onDiscoveryEvent` methods that delegate to the `ScannerPort`.
   - Returns an `ElectronBookImportService` type extending `BookImportService<number>` with the scanner methods.
3. Rewrite `apps/rishi-electron/src/renderer/src/services/book-import/index.ts` to export from shared (`BookFormat`, etc.) plus the adapter.
4. DJVU: ensure electron's `FormatsIpc.getDjvuData` exists. If not, the adapter's `FormatsPort` implementation throws a clear error when called for DJVU until the IPC method is added in a follow-up. Document this in a code comment. (The adapter unblocks the type system; runtime DJVU support is a separate task.)
5. Delete electron's local copies of `service.ts`, `importer.ts`, `indexer.ts`, `dispatch.ts`, `emitter.ts`, `types.ts` (non-scanner types) and their parallel `*.test.ts` files.
6. KEEP: `scanner-adapter.ts`, `scanner-adapter.test.ts`, `electron-adapter.ts`, new adapter test, `index.ts`.
7. Run all suites green.

#### New adapter test

`apps/rishi-electron/src/renderer/src/services/book-import/electron-adapter.test.ts` — mocks each IPC port, constructs the adapter, asserts:
- `importBook` calls through to shared logic with the correct mapped ports.
- `startDiscovery` calls the scanner.
- DJVU import returns a clear error if `getDjvuData` is not implemented.

#### Acceptance criteria

1. `grep -rn "BookFormat" apps/rishi-electron/src` shows only imports from `@rishi/shared/book-import` or the adapter / `index.ts`.
2. `'djvu'` is part of `BookFormat` on electron (verified via TS compile).
3. `apps/rishi-electron/src/renderer/src/services/book-import/service.ts` etc. no longer exist.
4. `apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.ts` and `electron-adapter.ts` exist.
5. Electron test suite green; shared test suite green.

#### Files

- **CREATED:**
  - `apps/rishi-electron/src/renderer/src/services/book-import/electron-adapter.ts`
  - `apps/rishi-electron/src/renderer/src/services/book-import/electron-adapter.test.ts`
- **DELETED:**
  - `apps/rishi-electron/src/renderer/src/services/book-import/service.ts` (+ test)
  - `apps/rishi-electron/src/renderer/src/services/book-import/importer.ts` (+ test)
  - `apps/rishi-electron/src/renderer/src/services/book-import/indexer.ts` (+ test)
  - `apps/rishi-electron/src/renderer/src/services/book-import/dispatch.ts` (+ test)
  - `apps/rishi-electron/src/renderer/src/services/book-import/emitter.ts` (+ test)
  - `apps/rishi-electron/src/renderer/src/services/book-import/types.ts` (non-scanner types only — scanner types merge into `scanner-adapter.ts` if present there)
- **MODIFIED:**
  - `apps/rishi-electron/src/renderer/src/services/book-import/index.ts` (re-export from shared + adapter)
  - `apps/rishi-electron/src/renderer/src/services/index.ts` (consume new factory)
- **KEPT:**
  - `apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.ts` (+ test)

#### Risk

**High.** The structural-port mismatch is the most complex DRY item. The adapter must be exercised by tests before deletion of the electron copies. If `getDjvuData` IPC is missing, electron DJVU import is broken until the IPC method is added — but the unified type closes EBUG-003 at the type level.

---

### 3.6 DRY-004 — Lift `renderRealtimeInstructions` Helpers

**Closes:** R-004, D-012, EBUG-002, T-005, T-006

#### Behavior contract

Electron's `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-158` deletes the inline `renderOutlineSection`, `renderActiveParagraphSection`, `renderVisualSection` and imports `renderRealtimeInstructions` from `@rishi/shared/voice-chat/build-realtime-agent` (mobile pattern at `apps/mobile/lib/voice-chat/realtime-session.ts:46` is the template). The function `buildRealtimeAgent` retains its purpose — constructing a `@openai/agents/realtime` `RealtimeAgent`. It just stops inlining the prompt helpers.

A new parity test guarantees both clients produce byte-identical instructions for the same inputs.

#### Canonical reference

- Shared: `packages/shared/src/voice-chat/build-realtime-agent.ts` (exports `renderRealtimeInstructions`)
- Electron (to remove inline copies): `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-158`
- Mobile (template): `apps/mobile/lib/voice-chat/realtime-session.ts:46`

#### Migration sequence

1. Author `packages/shared/__tests__/voice-chat/promptParity.test.ts` — feeds a fixed fixture (`{ pageText, language, outline, activeParagraphText, visualSummary }`) into the shared `renderRealtimeInstructions` and asserts a snapshot. (RED currently passes — but tests the contract.)
2. In `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`:
   - Delete lines 114-158 (`renderOutlineSection`, `renderActiveParagraphSection`, `renderVisualSection`).
   - Replace the call sites in `buildRealtimeAgent` with `renderRealtimeInstructions(args)` from `@rishi/shared/voice-chat/build-realtime-agent`.
3. Delete `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts` if its assertions are covered by shared's `build-realtime-agent.test.ts`. Otherwise, refactor to test electron's `buildRealtimeAgent` (the agent construction wrapper) rather than the render helpers.
4. Run shared + electron tests green.

#### Acceptance criteria

1. `grep -rn "renderOutlineSection\|renderActiveParagraphSection\|renderVisualSection" apps/rishi-electron/src` returns zero matches.
2. `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts` imports from `@rishi/shared/voice-chat/build-realtime-agent`.
3. `packages/shared/__tests__/voice-chat/promptParity.test.ts` passes with a snapshot.
4. Shared `build-realtime-agent.test.ts` still passes.
5. `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts` either passes (refactored) or is removed with a referenced replacement.

#### Files

- **MODIFIED:** `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`
- **MODIFIED or DELETED:** `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts`
- **CREATED:** `packages/shared/__tests__/voice-chat/promptParity.test.ts`

#### Risk

**Low.** Helpers are byte-for-byte copies. The risk is electron's local helpers having a subtle whitespace difference — the parity snapshot test will catch this.

---

### 3.7 DRY-005 — Chunk-ID Cross-Platform Parity Test

**Closes:** T-004, G-010

#### Behavior contract

A regression test guarantees that the same book bytes processed by either indexer produce identical chunk rows (`id`, `pageNumber`, `data`). If the current implementations diverge, the test is authored as `test.failing(...)` with a documented reason — the planner will schedule alignment as a separate task.

After DRY-003, electron's indexer is a thin adapter over the shared indexer. The test exercises both invocation paths.

#### Canonical reference

- Shared indexer: `packages/shared/src/book-import/indexer.ts`
- Electron indexer (deleted by DRY-003): `apps/rishi-electron/src/renderer/src/services/book-import/indexer.ts`
- Adapter: `electron-adapter.ts` (DRY-003)

#### Investigation required

The coder must:

1. Read both indexer implementations.
2. Determine if chunk IDs are content-addressable (hash of text) or positional (sequential integer).
3. **Preferred:** content-addressable IDs (`sha256(text).slice(0,16)` or similar).
4. If shared and electron diverge, the test is `test.failing` and the planner schedules alignment.

#### Test

`packages/shared/__tests__/book-import/chunkIdParity.test.ts`:
- Inline fixture: a 2-page minimal EPUB-like input (raw text chunks).
- Calls the shared indexer; captures `{ id, pageNumber, data }` for each chunk.
- Calls the same input through the adapter (post-DRY-003).
- Asserts deep equality.

#### Acceptance criteria

1. The test file exists with at least one passing or `test.failing` case documented.
2. If passing: both paths produce identical chunk row shapes.
3. If `test.failing`: a TODO comment cites the specific divergence (e.g., "electron uses sequential IDs, shared uses content-addressable") and the planner adds a follow-up to align.

#### Files

- **CREATED:** `packages/shared/__tests__/book-import/chunkIdParity.test.ts`

#### Risk

**Low (test-only).** Worst case: the test passes with `test.failing`, documenting divergence for the planner. No production code change required.

---

### 3.8 CONTEXT-001 — Mobile Activation Context: Real Page Text

**Closes:** T-007

#### Behavior contract

Each of the 4 mobile readers populates `pageText` in `getActivationContext()` with the actual rendered prose of the current view, matching electron's contract.

#### Canonical reference

- Electron: `apps/rishi-electron/src/renderer/src/stores/chatStore.ts:71` —
  ```typescript
  const pageText = playerState.currentParagraphs.map((p) => p.text).join('\n')
  ```
  The text content of all currently-rendered paragraphs, newline-joined.
- Mobile bug sites:
  - EPUB: `apps/mobile/app/reader/[id].tsx:761` (`pageText: chapterLabel ?? ''`)
  - PDF: `apps/mobile/app/reader/pdf/[id].tsx:700-704` (`pageText: 'Page N of M'`)
  - MOBI: `apps/mobile/app/reader/mobi/[id].tsx:699` (`pageText: 'Chapter ${currentChapter + 1}'`)
  - DJVU: `apps/mobile/app/reader/djvu/[id].tsx:577-581` (`pageText: 'Page N of M'`)

#### Cap

Electron does not cap. Mobile applies a soft cap of 8,000 characters. If exceeded, trim to the last paragraph boundary before the cap and append `\n[text truncated]`.

#### Per-reader implementation

**EPUB** — `@epubjs-react-native/core` renders in a WebView. Use `epubRef.current?.injectJavascript(...)` to extract `document.body.innerText` on each `onLocationChange`, store in a `useRef<string>`, surface via `getActivationContext`. If the lib exposes `getCurrentSection()` or similar, prefer that.

**PDF** — `react-native-pdf`. Try `pdfRef.current?.getPageText(pageNumber)` (verify version). Fallback: pre-computed page text from the book-import indexer's `data` field for the chunk(s) on that page.

**MOBI** — Rendered in a WebView. Inject JS: `window.ReactNativeWebView.postMessage(JSON.stringify({ kind: 'page-text', text: document.body.innerText }))` on chapter render; capture via `onMessage`; store in a `useRef`.

**DJVU** — Fallback path same as PDF: pull from the indexer's chunk data for the current page number.

#### Soft-cap helper

`packages/shared/src/voice-chat/pageTextCap.ts` — NEW:

```typescript
export function softCapPageText(text: string, max: number = 8000): string
```

Trims at the last `\n\n` (paragraph break) before `max`, or last `.` before `max`, or hard-cuts. Appends `\n[text truncated]` if trimmed.

Used by all 4 readers' `getActivationContext`.

#### Acceptance criteria

1. **EPUB:** `apps/mobile/__tests__/readers/epubActivationContext.test.tsx` — renders reader with fixture EPUB, simulates `onLocationChange` carrying real text, asserts `getActivationContext().pageText` contains expected prose, `length > 50`, not equal to a chapter label.
2. **PDF:** equivalent for PDF reader (uses fallback path with stub `getPageText` mock).
3. **MOBI:** equivalent — simulates `onMessage` event delivering page text.
4. **DJVU:** equivalent — uses indexer fallback.
5. **Cap:** `packages/shared/__tests__/voice-chat/pageTextCap.test.ts` — asserts a 10K-char input is trimmed to ≤ 8000 + suffix.
6. **Integration:** A test verifies that the `AgentFactoryArgs.pageText` passed into the voice-chat agent factory is the cap'd, real text.

#### Files

- **CREATED:**
  - `packages/shared/src/voice-chat/pageTextCap.ts`
  - `packages/shared/__tests__/voice-chat/pageTextCap.test.ts`
  - `apps/mobile/__tests__/readers/epubActivationContext.test.tsx`
  - `apps/mobile/__tests__/readers/pdfActivationContext.test.tsx`
  - `apps/mobile/__tests__/readers/mobiActivationContext.test.tsx`
  - `apps/mobile/__tests__/readers/djvuActivationContext.test.tsx`
- **MODIFIED:**
  - `apps/mobile/app/reader/[id].tsx`
  - `apps/mobile/app/reader/pdf/[id].tsx`
  - `apps/mobile/app/reader/mobi/[id].tsx`
  - `apps/mobile/app/reader/djvu/[id].tsx`

#### Risk

**Medium.** WebView text extraction is fiddly; race conditions between `onLoad` and `injectJavascript` exist. The fallback path (using the indexer's chunk data) is the conservative escape hatch — if WebView extraction is unreliable for any reader, fall back to the indexer.

---

### 3.9 WIRING-001 — `setChatVoicePort` Startup Wiring

**Closes:** R-006, T-002

#### Behavior contract

A live mobile voice-chat service is constructed once at app startup and `setChatVoicePort(service)` is called once. After this call:

- `useChatStore.getState().voiceState` reflects the live service's state.
- `useChatStore.getState().chatStatus` reflects live chat status.
- The `onEndedByAgent` subscription on `chatStore` is wired to the live service.

In production, `port` MUST NOT remain the `noopPort`.

#### Canonical reference

- The wiring function (already implemented): `apps/mobile/lib/stores/chatStore.ts:83` (`setChatVoicePort`)
- The gap: no production caller exists. `grep -r "setChatVoicePort" apps/mobile/app` returns nothing.

#### Implementation

Add a one-time wiring step in `apps/mobile/app/_layout.tsx` (or the existing root provider) that:

1. Constructs the voice-chat service using `createVoiceChatService` from `@rishi/shared/voice-chat`, supplying mobile's `mobileVoiceChatIpc`, `mobileMediaPort`, `mobileEffectsPort` (no-op on mobile if not yet implemented), `mobileClock`, etc.
2. Calls `setChatVoicePort(service)` exactly once.
3. **Auth-race gate (per REVIEW-01 MAJOR-06):** Service construction is gated on the Better Auth session being hydrated and non-null. Mobile's `_layout.tsx` already calls `useAuthStore((s) => s.hydrateAuth)` then `hydrateAuth()` on mount (line 122 of `_layout.tsx`); the store surfaces `sessionToken: string | null` and `user: { id, email } | null`. Wire via the same store:
   ```ts
   const session = useAuthStore((s) => (s.user && s.sessionToken ? s : null))
   useEffect(() => {
     if (!session) return
     if (wired) return
     setChatVoicePort(buildMobileVoiceChatService())
     wired = true
   }, [session])
   ```
   Service construction MUST NOT happen while `session === null`. This matches the canonical electron pattern where the voice-chat service is constructed only after `apiClient` is authenticated.
4. Hot reload (Fast Refresh) must not double-wire — guard with a module-level "wired" flag.

This is the same wiring the existing test fixture (`useVoiceChat.test.ts:37`) already exercises.

#### Acceptance criteria

1. `apps/mobile/__tests__/app/startupWiring.test.tsx` — mounts the provider in TWO states and asserts:
   - **State A (`useAuthStore` → `{ user: null, sessionToken: null }`):** `setChatVoicePort` is NOT called.
   - **State B (`useAuthStore` → `{ user: { id, email }, sessionToken: 'tok' }`):** `setChatVoicePort` is called exactly once with a non-noop port.
2. After mount in State B, the port reference is the live service (test asserts `getState`-like methods on the port are the service's).
3. Hot-reload simulation: re-mounting the layout (still in State B) does not call `setChatVoicePort` a second time.
4. `grep -r "setChatVoicePort" apps/mobile/app` returns at least one match.

#### Files

- **MODIFIED:** `apps/mobile/app/_layout.tsx` (or current root)
- **CREATED:** `apps/mobile/__tests__/app/startupWiring.test.tsx`
- **POSSIBLY CREATED:** `apps/mobile/lib/voice-chat/buildService.ts` — factory that assembles all the deps and returns the service (clean module to test in isolation).

#### Risk

**Low.** Mobile already has all the pieces — this is plumbing.

---

### 3.10 VAD-001 — Local VAD on Mobile

**Closes:** D-009, G-001

#### Behavior contract

Mobile gains a local VAD (voice activity detector) that operates during the realtime-connect window, mirroring the electron behavior. While the mic stream is being captured but the WebRTC peer is being established, the VAD identifies the speech onset and signals the activation pipeline to start recording for buffered replay.

The shared `packages/shared/src/voice-chat/local-vad.ts` is the canonical algorithm. Mobile needs a worklet-thread-based port using `react-native-worklets`.

#### Canonical reference

- Shared VAD algorithm: `packages/shared/src/voice-chat/local-vad.ts`
- Shared VAD test: `packages/shared/src/voice-chat/local-vad.test.ts`
- Mobile worklets dep: `apps/mobile/package.json:67` (`"react-native-worklets": "0.5.1"` — blocker lifted; can upgrade to `^0.6.0` or higher if needed)
- Electron VAD wiring (reference): post DRY-001, electron imports shared `createLocalVad`.

#### Implementation

1. Bump `react-native-worklets` to `^0.6.0` (worklet-thread support). Verify Reanimated compatibility; if there's a peer-dep conflict, bump Reanimated alongside.
2. Create `apps/mobile/lib/voice-chat/native-vad.ts` — a thin wrapper that runs the shared `createLocalVad` algorithm on a worklet thread, exposing the same signature (`{ start(stream), stop(), onSpeechStart(cb) }`) as the shared API.
3. Mobile audio sample source: bridge from React Native's audio stream. The mic stream comes from `MediaPort.getUserMedia`. The VAD needs raw PCM samples. Investigate whether `react-native-webrtc` exposes raw audio frames OR use `expo-audio` / a native module to tap the mic separately for VAD purposes.
4. **Investigation gate:** if no raw-audio path exists from `react-native-webrtc`, the coder must either (a) add a small native module that exposes audio frames, or (b) document the gap and treat VAD-001 as "blocked until raw audio access is available" (defer back to follow-up). The spec does NOT require shipping a native module if (a) is infeasible — but it does require a documented investigation result.
5. Wire the local VAD into the mobile voice-chat service factory.

#### Acceptance criteria

1. `react-native-worklets` is at `^0.6.0` or higher in `apps/mobile/package.json`.
2. The mobile build still succeeds (Reanimated peer-dep is satisfied).
3. `apps/mobile/__tests__/voice-chat/native-vad.test.ts` — feeds a fixture PCM stream into `native-vad`, asserts `onSpeechStart` fires within the expected sample window.
4. Integration: `apps/mobile/__tests__/voice-chat/connect-window.test.ts` — simulates the connect window, asserts the VAD signal flows into the activation pipeline.
5. If investigation gate fails: a markdown note `.parity-v2/VAD-001-investigation.md` documents the blocker, and VAD-001 is downgraded to deferred. The planner accepts the downgrade.

#### Files

- **MODIFIED:** `apps/mobile/package.json` (`react-native-worklets` bump, possibly `react-native-reanimated`)
- **CREATED:**
  - `apps/mobile/lib/voice-chat/native-vad.ts`
  - `apps/mobile/__tests__/voice-chat/native-vad.test.ts`
  - `apps/mobile/__tests__/voice-chat/connect-window.test.ts`
  - possibly a native module under `apps/mobile/modules/` if raw audio is needed
- **POSSIBLY MODIFIED:** `apps/mobile/lib/voice-chat/service.ts` (wire the VAD into the deps)

#### Risk

**High.** Worklet bridging from RN audio streams is platform-specific. The investigation gate is a real possibility — if blocked, VAD-001 defers cleanly with a documented reason.

---

### 3.11 NAVHIST-001 — Navigation History Machine on Mobile

**Closes:** D-002

#### Behavior contract

Mobile gains a navigation history stack with the same depth/dwell semantics as electron's machine. A back-pill UI appears when the user navigates to a new section after dwelling on the current one for at least `DWELL_MS`. Tapping back navigates to the previous position. Tapping forward (if a forward stack exists) navigates the other way.

Per-book stack scope. Max depth `STACK_MAX_DEPTH`.

#### Canonical reference

- Electron machine: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts`
- Supporting: `navigationHistoryActor.ts`, `pageKey.ts`, `types.ts`
- Constants: `STACK_MAX_DEPTH`, `DWELL_MS` in `types.ts`

#### Migration strategy

Per R-007, the electron machine is NOT lifted to shared verbatim — its `AnchorPoint` shape and pill UI are electron-specific. Instead:

1. Port the `navigationHistoryMachine` to a platform-neutral form in shared (or vendor it under `apps/mobile/lib/machines/navigationHistory/` — coder's choice; prefer shared if the `AnchorPoint` shape can be parameterized).
2. The shared machine is parametric on `PageKey` / `Anchor` types.
3. **`resumeMap` shape (per REVIEW-01 MINOR-05):** the shared machine's XState context MUST use `Record<string, AnchorPoint>` for `resumeMap` (NOT `Map<string, AnchorPoint>`) — the plain-object form is JSON-serializable and works with XState devtools/inspectors. If electron's current implementation uses a native `Map`, it can keep that locally via a small adapter at the consumption boundary; the shared machine's authoritative type is `Record<string, AnchorPoint>`.
4. Electron switches to consume the shared machine (turning NAVHIST-001 into another DRY win) IF the port is clean. If the port introduces friction, ship the mobile copy first and align electron in a follow-up.
5. Mobile renders the back-pill using Reanimated (not CSS transitions).
6. Wire the machine into each of the 4 readers' navigation handlers.

#### Acceptance criteria

1. `apps/mobile/lib/machines/navigationHistory/` exists (or shared) with `navigationHistoryMachine.ts`, `pageKey.ts`, `types.ts`.
2. `apps/mobile/__tests__/machines/navigationHistoryMachine.test.ts` — covers push, pop, depth cap, dwell-gated pill emission.
3. `apps/mobile/components/reader/BackPill.tsx` — NEW component.
4. The 4 readers wire the machine: pressing a chapter/page navigation pushes onto the stack; pill shows after `DWELL_MS`; tapping pill restores.
5. Cross-book scope test: navigating to a different book resets the stack for that book.
6. Pill UI test: renders correctly, dismisses on timeout.

#### Files

- **CREATED:**
  - `apps/mobile/lib/machines/navigationHistory/navigationHistoryMachine.ts` (or under shared)
  - `apps/mobile/lib/machines/navigationHistory/pageKey.ts`
  - `apps/mobile/lib/machines/navigationHistory/types.ts`
  - `apps/mobile/components/reader/BackPill.tsx`
  - `apps/mobile/__tests__/machines/navigationHistoryMachine.test.ts`
  - `apps/mobile/__tests__/components/BackPill.test.tsx`
- **MODIFIED:**
  - `apps/mobile/app/reader/[id].tsx`
  - `apps/mobile/app/reader/pdf/[id].tsx`
  - `apps/mobile/app/reader/mobi/[id].tsx`
  - `apps/mobile/app/reader/djvu/[id].tsx`

#### Risk

**High.** The machine porting requires deep familiarity with XState's `setup()` API and the electron-specific `AnchorPoint` shape. Test-first will surface coupling issues early. The pill UI on Reanimated is novel for mobile but conventional.

---

## 4. Deferred / Done Items

Items NOT in scope this round. The first three (BILLING-001-CLOSED, BILLING-003-CLOSED, EBUG-001-CLOSED) were planned in the original draft but verified as already implemented on `main` by REVIEW-01. They are kept here as authoritative pointers so the planner and future researchers do not re-open them.

### 4.0a BILLING-001-CLOSED — Realtime Usage Reporting

**Closes (already done):** B-001, B-002, B-003, B-004, T-003 (implementation), D-004

**Reason:** Already implemented; closed by commits `d7aa59cf` (mobile wiring) and `d5ac52fc` (electron wiring).

**Existing implementation pointers (verified 2026-06-04):**

- Shared accumulator: `packages/shared/src/billing/realtime-usage-accumulator.ts`
- Shared client: `packages/shared/src/billing/realtime-usage-client.ts` (+ `realtime-usage-client.test.ts`)
- Shared exports: `packages/shared/package.json:66-67`
- Mobile `response.done` extraction + `usage.add(...)`: `apps/mobile/lib/voice-chat/realtime-session.ts:280-298`
- Mobile flush + POST: `apps/mobile/lib/voice-chat/realtime-session.ts:364-374`
- Electron import: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts:14`
- Electron wiring: `apps/rishi-electron/src/renderer/src/services/index.ts:262` (`billing: { apiFetch: workerFetch }`)
- Worker endpoint: `workers/worker/src/index.ts:242-252`

**Residual:** Mobile integration-test coverage is verified by §3.1 BILLING-AUDIT-001 (no production-code changes).

---

### 4.0b BILLING-003-CLOSED — Customer Portal Link

**Closes (already done):** D-005

**Reason:** Already implemented on both clients.

**Existing implementation pointers (verified 2026-06-04):**

- Mobile: `apps/mobile/app/(tabs)/settings/index.tsx:67-175` — `handleManageBilling` POSTs to `/api/billing/portal`, opens with `WebBrowser.openBrowserAsync`. Button at line 165-175.
- Electron: `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx:37-118` — same pattern with `workerFetch`. Button at line 114-118.
- Electron test: `apps/rishi-electron/src/renderer/src/routes/settings/account.test.tsx:40,52` covers click → POST → open URL.

**Residual:** Confirm mobile settings test covers the Manage-billing row. If missing, add one (5-minute task — tracked in PLAN as T-P2.x audit).

---

### 4.0c EBUG-001-CLOSED — Idempotent Welcome Credit + Subscription

**Closes (already done):** EBUG-001, D-006, T-008

**Reason:** Already idempotent. The original spec/research cited `workers/worker/src/billing/stripe.ts:21-42` as containing a non-idempotent `applyWelcomeCreditAndSubscription`; verification shows that function does not exist. The actual implementation is in `workers/worker/src/billing/backfill.ts:31-85` (`ensureCreditAndSubscription`), called from `workers/worker/src/auth.ts` `onCustomerCreate`.

**Existing implementation pointers (verified 2026-06-04):**

- `workers/worker/src/billing/backfill.ts:31-85` — `ensureCreditAndSubscription`. Checks `customer.balance <= -WELCOME_CREDIT_CENTS` and lists subscriptions to skip duplicates.
- `workers/worker/src/auth.ts:onCustomerCreate` calls `ensureCreditAndSubscription`.
- Idempotency test: `workers/worker/src/billing/backfill.test.ts:491-508` already covers the two-call → no duplicate path.

---

### 4.1 D-001 — P2P Book-Sharing on Mobile

**Reason:** Electron's P2P stack (`actors/sharing/` 11 actors, 15 UI components, `sessionMachine.ts`, `@rishi/sharing-protocol`) is a multi-thousand-line subsystem. Building a mobile equivalent is an independent effort comparable in size to all 13 items above combined.

**Unblocks when:** A separate roadmap commitment is made; `@rishi/sharing-protocol` zod v4 issue (R-008) is resolved; product confirms mobile P2P sharing is in-scope at all.

### 4.2 G-002 — Page-Curl Animation

**Reason:** Requires `@shopify/react-native-skia` as a new dependency. Skia adds build complexity and APK size; not justified without product demand.

**Unblocks when:** Skia is added for another feature, OR product prioritizes a richer page-turn animation over the current swipe.

### 4.3 G-005 — Cover-Extraction Error UX

**Reason:** Mechanism exists (`packages/shared/src/formats/epub-cover.ts`); the gap is error-state UX (no retry CTA on failed extraction). Cosmetic; does not block billing or correctness.

**Unblocks when:** Either (a) a small follow-up sprint is allocated for UX polish, or (b) the cover-extraction error is found to be more frequent than expected in production telemetry.

### 4.4 G-009 — Ready Chime + Thinking Sound

**Reason:** `expo-audio` is installed but the polish layer is P3. Not blocking any billing or correctness path. Sound design assets are needed first.

**Unblocks when:** Sound assets are sourced AND the rest of this spec's billing/DRY work is shipping cleanly.

### 4.5 R-008 — Lift Session Machine / `@rishi/sharing-protocol`

**Reason:** `apps/rishi-electron/src/renderer/src/machines/sessionMachine.ts:12` depends on `@rishi/sharing-protocol/schemas`, which uses zod v4. The package cannot currently be consumed via `import type` without breaking XState's `setup()` inference. Independent of mobile parity.

**Unblocks when:** zod v4 type-cascade issue in the sharing-protocol package is resolved (separate workstream).

### 4.6 R-007 — Lift Electron Navigation History to Shared

**Reason:** Superseded by NAVHIST-001 in this round. NAVHIST-001 may end up lifting the machine to shared as a byproduct, in which case R-007 is closed.

**Unblocks when:** NAVHIST-001 ships. If NAVHIST-001 keeps mobile and electron versions separate, R-007 becomes a follow-up.

---

## 5. Cross-Cutting Constraints

### 5.1 TDD discipline

Every item authors failing tests first. The plan (PHASE-1 RED, PHASE-2 GREEN) is enforced by the planner. No item ships without a passing test in CI.

### 5.2 Do not break existing electron behavior

- DRY-001..004 migrations: electron's test suite must remain green after each migration. If a shared-vs-electron behavioral difference surfaces, the shared module is updated to match electron (not the other way around).
- The signup billing flow must keep working through EBUG-FIX-001 — both first-time-user and "already-existing-customer" paths return a valid `subscriptionId`.

### 5.3 Non-breaking shared API additions

- `RealtimeUsage` and `reportRealtimeUsage` are already exported (see §4.0a) — no new shared changes for realtime usage in this round.
- `linkOrCopyFile` on `TtsIpcChannels` is OPTIONAL — non-breaking.
- `BillingInactiveError` + `checkBillingGate` are new exports — purely additive, non-breaking.
- `navigationHistoryMachine` shared port uses `Record<string, AnchorPoint>` for `resumeMap` to keep XState devtools/inspector friendly (per REVIEW-01 MINOR-05).

### 5.4 Secrets / env unchanged

No new env vars. `STRIPE_*`, `OPENAI_API_KEY`, `BETTER_AUTH_SECRET`, `WORKER_URL`, `PUBLIC_WEB_URL`, and trusted origins are unchanged.

### 5.5 Pnpm + Node-linker invariants

`apps/rishi-electron` uses `node-linker=hoisted` (per `project_electron_pnpm_linker.md`). Do not introduce a workspace dependency on a package that's not already in `apps/rishi-electron/package.json`. `pnpm@10.22.0` is pinned (per `project_pnpm_pin.md`).

### 5.6 No regression on existing tests

The full monorepo `pnpm test` must pass with zero new failures after each item lands.

### 5.7 Commit hygiene

Per `feedback_worktree_for_agents.md`: agents commit one issue at a time on a branch in the main checkout; verify clean working tree first.

### 5.8 Verification before claims

Per `verification-before-completion`: no "this works" claim is made without running the relevant test commands and reporting their output.

---

## 6. RESEARCH.md Finding → SPEC Item Mapping

Updated after REVIEW-01 (2026-06-04):

| Finding | Status | SPEC Item |
|---|---|---|
| D-001 | DEFERRED | §4.1 (P2P scope) |
| D-002 | IN-SCOPE | §3.11 NAVHIST-001 |
| D-003 | IN-SCOPE | §3.2 BILLING-002 |
| D-004 | DONE | §4.0a BILLING-001-CLOSED |
| D-005 | DONE | §4.0b BILLING-003-CLOSED |
| D-006 | DONE | §4.0c EBUG-001-CLOSED |
| D-007 | DONE / INFO | No action — `rishimobile://` already added |
| D-008 | DONE / INFO | Operator runs backfill script before go-live |
| D-009 | IN-SCOPE | §3.10 VAD-001 |
| D-010 | IN-SCOPE | §3.4 DRY-002 |
| D-011 | IN-SCOPE | §3.3 DRY-001 |
| D-012 | IN-SCOPE | §3.6 DRY-004 |
| D-013 | IN-SCOPE | §3.5 DRY-003 |
| G-001 | IN-SCOPE | §3.10 VAD-001 |
| G-002 | DEFERRED | §4.2 (Skia dep) |
| G-003 | DONE / OUT | Pre-existing z-index bug; out of scope this round |
| G-004 | DONE | Closed in parity-v1 |
| G-005 | DEFERRED | §4.3 (cover UX) |
| G-006 | IN-SCOPE | §3.6 DRY-004 (superseded) |
| G-007 | DONE | Closed |
| G-008 | DONE | Closed |
| G-009 | DEFERRED | §4.4 (audio polish) |
| G-010 | IN-SCOPE | §3.7 DRY-005 |
| R-001 | IN-SCOPE | §3.3 DRY-001 (superseded) |
| R-002 | IN-SCOPE | §3.4 DRY-002 (superseded) |
| R-003 | IN-SCOPE | §3.5 DRY-003 (superseded) |
| R-004 | IN-SCOPE | §3.6 DRY-004 (superseded) |
| R-005 | DONE / INFO | Billing types already correctly shared |
| R-006 | IN-SCOPE | §3.9 WIRING-001 (superseded) |
| R-007 | DEFERRED / SUPERSEDED | §4.6 — possibly closed as byproduct of NAVHIST-001 |
| R-008 | DEFERRED | §4.5 (zod v4) |
| R-009 | IN-SCOPE | §3.4 DRY-002 (superseded) |
| T-001 | IN-SCOPE | §3.2 BILLING-002 (superseded) |
| T-002 | IN-SCOPE | §3.9 WIRING-001 (superseded) |
| T-003 | PARTIAL — DONE + AUDIT | §4.0a (impl done) + §3.1 BILLING-AUDIT-001 (mobile integration-test gap) |
| T-004 | IN-SCOPE | §3.7 DRY-005 (superseded) |
| T-005 | IN-SCOPE | §3.6 DRY-004 (superseded) |
| T-006 | IN-SCOPE | §3.6 DRY-004 (superseded) |
| T-007 | IN-SCOPE | §3.8 CONTEXT-001 (superseded) |
| T-008 | DONE | §4.0c EBUG-001-CLOSED |
| B-001 | DONE | §4.0a BILLING-001-CLOSED |
| B-002 | DONE | §4.0a BILLING-001-CLOSED |
| B-003 | DONE | §4.0a BILLING-001-CLOSED |
| B-004 | DONE | §4.0a BILLING-001-CLOSED |
| EBUG-001 | DONE | §4.0c EBUG-001-CLOSED |
| EBUG-002 | IN-SCOPE | §3.6 DRY-004 (superseded) |
| EBUG-003 | IN-SCOPE | §3.5 DRY-003 (superseded) |

**Totals (post-REVIEW-01):** 11 IN-SCOPE items absorbing 24 findings; 6 DEFERRED items absorbing 6 findings; 3 DONE (closed-on-main) items absorbing 9 findings (BILLING-001/003/EBUG-001 families); 11 DONE/INFO findings requiring no spec entry.

---

## 7. Open Questions for the Planner

### Q1. (CLOSED post-REVIEW-01) Electron SDK hook for BILLING-001

Resolved: BILLING-001 is closed on `main` (see §4.0a). The SDK hook investigation is no longer required for this round; the existing electron wiring at `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts:14` is the canonical reference.

### Q2. NAVHIST-001 — share or vendor?

NAVHIST-001 §3.13 leaves the lift-to-shared decision to the coder ("port to shared if clean, vendor in mobile if friction"). The planner should resolve this upfront: lift first (and have electron consume the shared machine in the same PR — closing R-007 in this round), OR ship mobile-only first (and treat R-007 as a follow-up). Lifting upfront is cleaner; vendoring first is faster. Decision affects the sequencing.

### Q3. VAD-001 — accept investigation gate as a real failure mode?

§3.12 lists a documented investigation gate: if no raw-audio access path exists from `react-native-webrtc`, VAD-001 is downgraded to deferred. The planner should confirm this is acceptable, OR allocate budget for a small native module (which is significantly more effort). If a native module is required, VAD-001's risk goes from "High / may defer" to "High / committed implementation."

### Q4 (bonus). DRY-005 chunk-ID divergence — block on alignment or accept `test.failing`?

§3.8 allows the chunk-ID parity test to ship as `test.failing` if current implementations diverge. The planner should decide: align indexer IDs in this round (extra scope), or accept the `test.failing` documentation and schedule alignment separately. Recommendation: accept `test.failing` to keep this round bounded; schedule alignment as the next bugfix issue.

---

**End of SPEC.md**
