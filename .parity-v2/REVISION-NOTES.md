# REVISION-NOTES.md — SPEC + PLAN Revision after REVIEW-01

**Revision date:** 2026-06-04
**Source review:** `.parity-v2/REVIEW-01.md` (REVISE verdict; 3 BLOCKING, 6 MAJOR, 5 MINOR, 10 APPROVALS)

---

## Summary

| Metric | Pre-revision | Post-revision |
|---|---|---|
| SPEC §3 in-scope items | 13 | **11** |
| SPEC §4 deferred items | 6 (D-001, G-002, G-005, G-009, R-007, R-008) | 9 (+ §4.0a/b/c done-on-main pointers) |
| PLAN total tasks | 26 | **21** (−9 removed, +4 added) |
| RESEARCH→SPEC mapping totals | 13 in-scope / 6 deferred / 11 done-info / 30 absorbed | 11 in-scope / 6 deferred / 3 done-on-main / 11 done-info |

---

## BLOCKING fixes

### BLOCKING-01 — BILLING-001 already implemented
- **SPEC:** removed §3.1 BILLING-001 (was 100+ lines); replaced with §3.1 BILLING-AUDIT-001 (mobile integration-test verification only, ~30 lines). Added §4.0a BILLING-001-CLOSED with all file:line pointers (`packages/shared/src/billing/realtime-usage-{accumulator,client}.ts`, `apps/mobile/lib/voice-chat/realtime-session.ts:280-298,364-374`, `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts:14`, `apps/rishi-electron/src/renderer/src/services/index.ts:262`).
- **PLAN:** removed T-P0.1 (SDK spike), T-P1.1 (shared types), T-P1.2 (retry helper), T-P2.2 (mobile half), T-P4.2 (electron half), T-P5.3 (integration test). Added new T-P2.2 BILLING-AUDIT-001 (single mobile integration test).
- **§6 mapping:** B-001/B-002/B-003/B-004 → DONE; D-004 → DONE; T-008 → DONE; T-003 → PARTIAL (impl done + AUDIT residual).

### BLOCKING-02 — EBUG-FIX-001 already idempotent
- **SPEC:** removed §3.10 EBUG-FIX-001. Added §4.0c EBUG-001-CLOSED citing `workers/worker/src/billing/backfill.ts:31-85` `ensureCreditAndSubscription`, `workers/worker/src/auth.ts:onCustomerCreate`, idempotency test `workers/worker/src/billing/backfill.test.ts:491-508`.
- **PLAN:** removed T-P4.1. Phase 4 is now empty.
- **§6 mapping:** D-006 → DONE; EBUG-001 → DONE.

### BLOCKING-03 — BILLING-003 portal link already implemented
- **SPEC:** removed §3.3 BILLING-003. Added §4.0b BILLING-003-CLOSED citing `apps/mobile/app/(tabs)/settings/index.tsx:67-175,165-175`, `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx:37-118,114-118`, `account.test.tsx:40,52`.
- **PLAN:** removed both portal-link halves. Added tiny T-P2.4 (5-min test-presence audit — only authors a test file if `apps/mobile/__tests__/settings/` is missing one).
- **§6 mapping:** D-005 → DONE.

---

## MAJOR fixes

### MAJOR-02 — body-shape citation
- SPEC §3.1 (now BILLING-AUDIT-001) and §4.0a cite the inline worker handler at `workers/worker/src/index.ts:242-252`, no longer a non-existent `workers/worker/src/billing/realtime-usage.ts`.

### MAJOR-03 — Phase-3 `services/index.ts` race
- PLAN: T-P3.1, T-P3.2, T-P3.3, T-P3.5 each insert a `// PARITY-V2: <ITEM>-MIGRATED` comment marker in `services/index.ts` instead of swapping imports. NEW **T-P3.6** sequenced after them collects markers and resolves imports in a single PR. B-4 parallelization batch updated; B-5 added as the explicit serialization point.

### MAJOR-06 — WIRING-001 auth-race gate
- SPEC §3.9 names the canonical signal: `useAuthStore((s) => s.user && s.sessionToken ? s : null)` (mobile already exposes this via `apps/mobile/lib/stores/authStore.ts`; `_layout.tsx` already calls `hydrateAuth` on mount). Acceptance criterion now requires a two-state mount test (State A: `{ user: null, sessionToken: null }` → no construction; State B: hydrated → exactly one construction).
- PLAN T-P2.1 acceptance updated to match.

(MAJOR-01, MAJOR-04, MAJOR-05 were moot per BLOCKING-01/02 removal.)

---

## MINOR fixes

### MINOR-02 — interceptor JSON-parse failure case
- PLAN T-P1.3 acceptance criterion 4 added: `{ status: 402, body: 'not-json' }` → no throw; original response remains readable.

### MINOR-03 — DRY-001 file-count gate
- PLAN T-P3.1 documents the actual `ls apps/rishi-electron/src/renderer/src/services/voice-chat/` result: 19 files (10 source + 8 test + 1 `activation-program.ts` helper). Reviewer gate updated.

### MINOR-05 — NAVHIST-001 `resumeMap` shape
- SPEC §3.11 strategy point 3 specifies `resumeMap: Record<string, AnchorPoint>` (JSON-serializable for XState devtools/inspectors). Electron can keep a `Map` internally via a one-line boundary adapter.
- PLAN T-P1.6 outputs note the same; tests include a `JSON.parse(JSON.stringify(snapshot.context))` round-trip.
- PLAN T-P3.5 documents the `Record` ⇄ `Map` boundary adapter.

(MINOR-01 verified pass — no edits needed. MINOR-04 verified — T-P0.2 chunk-ID spike retained as a Phase-0 task.)

---

## Final task inventory (PLAN)

| Phase | Tasks |
|---|---|
| Phase 0 | T-P0.0, T-P0.1 (VAD compat), T-P0.2 (chunk-ID) |
| Phase 1 | T-P1.3, T-P1.4, T-P1.5, T-P1.6 |
| Phase 2 | T-P2.1, T-P2.2 (NEW: BILLING-AUDIT), T-P2.3, T-P2.4 (NEW: portal-test audit), T-P2.5, T-P2.6, T-P2.7 |
| Phase 3 | T-P3.1, T-P3.2, T-P3.3, T-P3.4, T-P3.5, T-P3.6 (NEW: services/index.ts merge) |
| Phase 4 | (removed) |
| Phase 5 | T-P5.1 |
| **Total** | **21** |

---

## Final §3 in-scope inventory (SPEC)

1. §3.1 BILLING-AUDIT-001 (NEW)
2. §3.2 BILLING-002
3. §3.3 DRY-001
4. §3.4 DRY-002
5. §3.5 DRY-003
6. §3.6 DRY-004
7. §3.7 DRY-005
8. §3.8 CONTEXT-001
9. §3.9 WIRING-001
10. §3.10 VAD-001
11. §3.11 NAVHIST-001

---

## Open follow-ups (for next reviewer)

- Confirm `apps/mobile/__tests__/settings/` actually lacks a Manage-billing row test (drives T-P2.4 from no-op to 1-file create).
- Confirm electron's existing `reportRealtimeUsage` wiring is exercised by an electron test (drives T-P2.2 audit grep — if it finds nothing, queue a follow-up issue).
- Verify `apps/mobile/lib/stores/authStore.ts` hydration timing: does `hydrateAuth()` resolve before any reader can fire an `apiClient` request? If race exists in practice, T-P2.1's `useEffect` gate is sufficient but consider Suspense-based gating instead.
