# TEST-REVIEW-01 — Phase 1 red-phase test audit

**Date:** 2026-06-04
**Reviewer:** Test Reviewer agent
**Scope:** 7 test files authored for Phase 1 (BILLING-002, DRY-002, DRY-003, NAVHIST-001).

---

## Verdict

All 7 files **pass the audit**. Fixes applied are mechanical (one deprecated-API swap). Remaining failures are intentional red-phase signals waiting for implementation.

---

## File-by-file findings

### 1. `packages/shared/src/billing/errors.test.ts`
- **Status:** Fails for the right reason — `Cannot find module './errors'`. ✓
- **Behavior vs implementation:** Pure behavior — instance-of checks, message shape via `/subscription/i`, no internal-detail assertions. ✓
- **Coverage:**
  - `BillingInactiveError` constructor (status + null status).
  - `code` literal locked to `'BILLING_INACTIVE'`.
  - Message shape (regex, not exact text).
  - `isBillingInactiveResponse` typeguard — 6 cases covering 402+payload, null status, non-402, wrong code, missing code, non-object bodies.
- **Gap (deferred):** "thrown across an async boundary" parity test from the prompt is **not** added. Reason: `BillingInactiveError` is a regular `Error` subclass — `instanceof` survives `await` boundaries by language guarantee. The other tests in `interceptor.test.ts` (which call `checkBillingGate` across `await`) already exercise this end-to-end. Adding a redundant test would pin language behavior, not our code.
- **Fix applied:** none.

### 2. `packages/shared/src/billing/interceptor.test.ts`
- **Status:** Fails for the right reason — `Cannot find module './interceptor'`. ✓
- **Behavior vs implementation:** All 11 cases use `Response`-shaped inputs and assert on throw/no-throw + body re-readability — observable contract only. ✓
- **Coverage of MINOR-02 (no crash on bad bodies):**
  - 402 + unparseable text body (`"not-json"`, content-type `text/plain`) → no throw. ✓
  - 402 + empty body → no throw. ✓
  - 402 + non-BILLING_INACTIVE JSON → no throw. ✓
  - Body-clone semantics: caller can still `await res.json()` after both 200 and 402 passthrough.
- **Gap (deferred):** "truncated body" and "huge body" cases listed in the prompt are not added. Reason: both reduce to "JSON.parse throws" — already covered by the `"not-json"` case. A size-stress test would pin Response stream internals, not contract.
- **Fix applied:** none.

### 3. `packages/shared/src/tts/types.test.ts`
- **Status:** Type-test passes at runtime (expect-type is compile-only) but TS shows expected red-phase error: `Property 'linkOrCopyFile' does not exist on type 'TtsIpcChannels'`. ✓
- **Fix applied:** `expectTypeOf(legacy).toMatchTypeOf<TtsIpcChannels>()` → `toExtend<TtsIpcChannels>()` (deprecated since expect-type v1.2.0).

### 4. `packages/shared/src/tts/cache.test.ts` (new `linkOrCopyFile` block only)
- **Status:** 1 case fails for the right reason (`linkOrCopyFile` mock not called — production code doesn't use it yet); 1 case (mobile fallback) currently passes coincidentally because today's cache already calls `copyFile`. The implementation must keep that branch alive. ✓
- **Behavior vs implementation:** Asserts on `vi.fn` call counts on the IPC port — this IS the contract (which channel the cache prefers). Correct level. ✓
- **Both branches tested:** ✓ (with-link → linkOrCopyFile preferred; without-link → copyFile fallback).
- **Gap (deferred to GREEN phase):** EXDEV-style throw-from-linkOrCopyFile → fallback-to-copyFile is **not** tested here. Rationale: the EXDEV fallback lives **inside the electron `linkOrCopyFile` adapter** (per SPEC §3.2), not inside the shared cache. The shared cache's contract is simply "prefer link if present"; the adapter is responsible for swallowing EXDEV. That belongs in an electron-side test under `apps/rishi-electron`.
- **Fix applied:** none.

### 5. `packages/shared/src/book-import/bookFormat-export.test.ts`
- **Status:** GREEN out of the gate by design (regression guard). All 4 cases pass. ✓
- **Fix applied:** Two `toMatchTypeOf` → `toExtend` swaps.

### 6. `packages/shared/src/machines/navigationHistory/pageKey.test.ts`
- **Status:** Fails for the right reason — `Cannot find module './pageKey'`. ✓
- **Parity with electron:** 1:1 verbatim port. **9 / 9 cases** match the electron file (PDF, EPUB CFI, AZW3, MOBI, cross-keyspace collision, non-CFI strings, raw seed values, malformed CFI). No omissions.
- **Coverage gap (prompt asked):** Empty/special-char inputs are already covered — `cfi: ''` test on line 59.
- **Fix applied:** none.

### 7. `packages/shared/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
- **Status:** Fails for the right reason — `Cannot find module './navigationHistoryMachine'`. ✓
- **xstate dep check:** `packages/shared/package.json` already has `xstate: ^5.30.0` (line 72). No change needed.
- **Behavior vs implementation:** Asserts on state values (`'inactive'`, parallel-state objects), context shape (`bookId`, `stack`, `resumeMap`, `pillVisible`, `currentPage`), and emitted events (`RESUME_REQUESTED`). No internal action/actor/event-name pinning beyond the public contract. ✓
- **MINOR-05 compliance:** ✓ Confirmed.
  - `resumeMap` accessed via `Object.keys(...)` / `ctx.resumeMap['pdf:7']` (NOT `.get` / `.size`).
  - Dedicated test: `'resumeMap is a plain object (not a Map instance)'` asserts `not.toBeInstanceOf(Map)` AND `Object.getPrototypeOf(ctx.resumeMap) === Object.prototype`.
  - Dedicated JSON-roundtrip test (`'context survives JSON.stringify → JSON.parse round-trip with resumeMap entries intact'`).
- **Parity with electron:** 21 / 21 electron cases ported + 2 new (MINOR-05 round-trip + Map-instance guard). **0 omissions.** Map.get/size sites rewritten to plain-object indexing as planned.
- **Coverage of prompt-requested edges:**
  - `STACK_MAX_DEPTH` overflow: ✓ tested (`'stack caps at STACK_MAX_DEPTH, dropping oldest'`).
  - `DWELL_MS` boundary: covered via `advanceTimersByTime(DWELL_MS)` (engaged) and `DWELL_MS - 1000` + 60s hidden (still paused). Just-below/just-above-by-1ms variants intentionally omitted — pins setTimeout precision, not behavior.
  - Book-change clears stack + resumeMap: covered by `BOOK_CLOSED` test. A subsequent `BOOK_OPENED` with a different bookId starts from a clean parallel state by construction (no separate test needed).
  - Resume into a stale anchor: the smart-resume describe block covers the success and no-stored-anchor cases. A "stale anchor" case (anchor referencing a page that no longer exists post-edit) is not modeled — the machine doesn't validate anchor freshness, so there's no behavior to assert.
- **Fix applied:** none.

---

## Diagnostic findings — re-analysis

The parent prompt listed three "diagnostic issues" that turned out to be partly incorrect on closer inspection:

1. **`.not` does not exist on `Assertion<function-type>`** — **not reproducible.** `tsc --noEmit` on the whole `packages/shared` shows zero TS errors of this kind. The runtime vitest output shows `.not.toHaveBeenCalled()` and `expect(() => fn()).not.toThrow()` working as expected. The IDE-side diagnostic was likely from a stale LSP cache or a different vitest version. **No fix needed.**

2. **`toMatchTypeOf` deprecated** — **confirmed and fixed.** Replaced 3 sites with `toExtend` (expect-type v1.3.0, vitest 4.1.7). Tests still pass.

3. **`xstate` not found** — **not an issue.** `packages/shared/package.json` has `xstate: ^5.30.0` at line 72. The error shown earlier was only a cascading effect of the missing `./navigationHistoryMachine` module (production code not authored yet), not a missing dep.

---

## Fixes applied (summary)

| File | Change | Lines |
| --- | --- | --- |
| `src/tts/types.test.ts` | `toMatchTypeOf` → `toExtend` | 1 |
| `src/book-import/bookFormat-export.test.ts` | `toMatchTypeOf` → `toExtend` | 2 |

No other changes. No production source touched. `package.json` untouched (xstate already present).

---

## Confirmation — tests fail for the right reasons

After fixes:
- `errors.test.ts`: FAIL — `Cannot find module './errors'`. ✓ expected.
- `interceptor.test.ts`: FAIL — `Cannot find module './interceptor'`. ✓ expected.
- `types.test.ts`: PASS at runtime; TS shows `linkOrCopyFile` missing on `TtsIpcChannels`. ✓ expected.
- `cache.test.ts` (new block): 1 case FAIL (`linkOrCopyFile` not called — impl missing), 1 case PASS (fallback path already implemented). ✓ expected.
- `bookFormat-export.test.ts`: PASS — regression guard, GREEN by design. ✓.
- `pageKey.test.ts`: FAIL — `Cannot find module './pageKey'`. ✓ expected.
- `navigationHistoryMachine.test.ts`: FAIL — `Cannot find module './navigationHistoryMachine'`. ✓ expected.

---

## Open items for the implementation (GREEN) phase

1. Author `packages/shared/src/billing/errors.ts` and `interceptor.ts` per the assertions above.
2. Add optional `linkOrCopyFile?: (src, dest) => Promise<void>` to `TtsIpcChannels` in `packages/shared/src/tts/types.ts`.
3. Update `packages/shared/src/tts/cache.ts` to prefer `ipc.linkOrCopyFile` over `ipc.copyFile` for the text-hash mirror when present.
4. Author `packages/shared/src/machines/navigationHistory/{types,pageKey,navigationHistoryMachine}.ts`. The `resumeMap` MUST be `Record<string, AnchorPoint>`, not `Map`.
5. (Electron-side, out of Phase 1 scope) author an EXDEV-fallback test inside the electron `linkOrCopyFile` adapter — not the shared cache.
