# REVIEW-02.md — Parity v2 Second-Round Audit

**Reviewer:** second-round spec+plan reviewer
**Review date:** 2026-06-04
**Documents audited:** `.parity-v2/SPEC.md` (revised), `.parity-v2/PLAN.md` (revised), `.parity-v2/REVISION-NOTES.md`, against `.parity-v2/REVIEW-01.md`
**Verdict:** **LOCK** (with one MINOR follow-up note)

---

## Confirmation of REVIEW-01 BLOCKERs

### BLOCKING-01 — CLOSED ✓
SPEC §3.1 BILLING-001 (the `VoiceChatIpc.reportUsage` design that would have created a duplicate POST path) is removed and replaced with a thin §3.1 BILLING-AUDIT-001 (test-only). §4.0a captures the closed-on-`main` implementation with concrete file:line pointers (`packages/shared/src/billing/realtime-usage-{accumulator,client}.ts`, `apps/mobile/lib/voice-chat/realtime-session.ts:280-298,364-374`, electron import sites). PLAN removed T-P0.1/T-P1.1/T-P1.2/T-P2.2(original)/T-P4.2/T-P5.3 and added a single audit test (T-P2.2). The new BILLING-AUDIT-001 has clear acceptance: one hermetic mobile integration test, zero production-code changes. **Well-spec'd.**

### BLOCKING-02 — CLOSED ✓
SPEC §3.10 EBUG-FIX-001 removed; §4.0c cites the real (already-idempotent) `workers/worker/src/billing/backfill.ts:31-85` `ensureCreditAndSubscription` and the existing test at `backfill.test.ts:491-508`. PLAN Phase 4 is empty.

### BLOCKING-03 — CLOSED ✓
SPEC §3.3 BILLING-003 removed; §4.0b cites mobile/electron portal-link sites and `account.test.tsx` coverage. A 5-min PLAN audit (T-P2.4) confirms mobile-test presence; this is appropriately scoped.

---

## Confirmation of REVIEW-01 MAJORs

### MAJOR-01, MAJOR-04, MAJOR-05 — moot per BLOCKER fixes ✓
Removed alongside BILLING-001/EBUG-001.

### MAJOR-02 — CLOSED ✓
SPEC §3.1 / §4.0a cite the actual inline worker handler at `workers/worker/src/index.ts:242-252` (the non-existent `workers/worker/src/billing/realtime-usage.ts` is gone).

### MAJOR-03 — CLOSED ✓
PLAN B-4 (parallel) batches T-P3.1/T-P3.2/T-P3.3/T-P3.5 each leaving a `// PARITY-V2: <ITEM>-MIGRATED` comment marker. NEW T-P3.6 (B-5, sequenced) collects markers and resolves imports in a single PR. Acceptance criteria for T-P3.1/2/3 explicitly state "leaves a comment marker (does NOT swap the import path in this task)" — not wishful. T-P3.4 correctly noted as exempt (touches `modules/buildRealtimeAgent.ts`, not `services/index.ts`).

### MAJOR-06 — CLOSED ✓
SPEC §3.9 names the canonical auth-gate signal `useAuthStore((s) => s.user && s.sessionToken ? s : null)`. **Verified at source:** `apps/mobile/lib/stores/authStore.ts` defines `user: AuthUser | null` (L47), `sessionToken: string | null` (L54), `hydrateAuth` (L89,127). `apps/mobile/app/_layout.tsx:122` declares `hydrateAuth`; the `useEffect` at L124-128 calls `void hydrateAuth()`. SPEC's wording "_layout.tsx already calls `hydrateAuth` on mount (line 122 of `_layout.tsx`)" is accurate within ±2 lines. Acceptance criterion now requires a two-state mount test (State A: `{ user: null, sessionToken: null }` → no construction; State B: hydrated → exactly one construction); PLAN T-P2.1 mirrors. Transition + Fast-Refresh cases also covered.

---

## Confirmation of REVIEW-01 MINORs

- **MINOR-01** (reader file paths) — re-verified pass, no change needed.
- **MINOR-02** (JSON-parse failure) — PLAN T-P1.3 acceptance criterion 4 added; covers `{ status: 402, body: 'not-json' }` → no throw. ✓
- **MINOR-03** (DRY-001 file-count gate) — **PARTIAL** (see new MINOR below).
- **MINOR-04** (chunk-ID spike retained) — T-P0.2 retained. ✓
- **MINOR-05** (`resumeMap` shape) — SPEC §3.11 strategy point 3 + §5.3 + PLAN T-P1.6 all specify `Record<string, AnchorPoint>` and add a JSON round-trip test. T-P3.5 documents the boundary adapter. ✓

---

## New issues discovered

### BLOCKING — none

### MAJOR — none

### MINOR

#### MINOR-NEW-01: T-P3.1 file-count gate over-corrects MINOR-03 with wrong file list

PLAN T-P3.1 (line ~250) claims:
> Verified file inventory: `activation-program.ts`, `billing.test.ts`, `emitter.test.ts`, `emitter.ts`, `errors.test.ts`, `errors.ts`, `index.ts`, `key-cache.test.ts`, `key-cache.ts`, `local-vad.test.ts`, `local-vad.ts`, `machine.coverage.test.ts`, `machine.test.ts`, `machine.ts`, `service.test.ts`, `service.ts`, `types.test.ts`, `types.ts`, `usage-extract.ts` — **19 files total** (10 source + 8 test + 1 activation-program helper).

**Actual `ls apps/rishi-electron/src/renderer/src/services/voice-chat/`:** **17 files** (9 source + 8 test). `billing.test.ts` and `usage-extract.ts` cited in the inventory do NOT exist. SPEC §3.3 separately says "8 source files + 6 test files" and "~14 files" — also wrong.

Impact: the reviewer "deletion gate count" is wrong, so the gate is unusable as-stated. The coder will see "19 files deleted" expected but only be able to delete 17, and the reviewer audit table will mismatch.

**Fix (one-line):** PLAN T-P3.1 set count to 17 (9 source + 8 test), drop the two phantom files; SPEC §3.3 update "8 source + 6 test" → "9 source + 8 test = 17" and remove the "~14 files" parenthetical.

Confidence: 99% (verified by direct `ls`).

### Orphaned-task / coverage scan

- No PLAN task lacks a SPEC item.
- No SPEC §3 item lacks a PLAN task. (§3.1 → T-P2.2; §3.2 → T-P1.3 + T-P2.3; §3.3 → T-P3.1 + T-P3.6; §3.4 → T-P1.4 + T-P3.2; §3.5 → T-P1.5 + T-P3.3; §3.6 → T-P3.4; §3.7 → T-P0.2 + T-P5.1; §3.8 → T-P2.5; §3.9 → T-P2.1; §3.10 → T-P0.1 + T-P2.7; §3.11 → T-P1.6 + T-P2.6 + T-P3.5.) Complete.
- Phase ordering is sound: B-2 (shared additive) → B-3 (mobile consumers, with T-P2.3 dep on T-P1.3, T-P2.6 dep on T-P1.6) → B-4 (electron deletions w/ markers) → B-5 (T-P3.6 merge) → B-6 (parity tests). No dependency breaks.
- **T-P5.2 subsumption defensible.** T-P3.4 explicitly produces `packages/shared/__tests__/voice-chat/promptParity.test.ts` (SPEC §3.6 acceptance criterion 3 and PLAN T-P3.4 outputs). A second parity test in Phase 5 would be pure duplication. SPEC §3.6's snapshot fixture is the parity check; no separate post-migration parity task is needed.

---

## APPROVALS

- **A-01** Three BLOCKERs cleanly removed from §3 with file:line evidence in §4.0a/b/c. PLAN tasks removed and accounted for in the revision log.
- **A-02** BILLING-AUDIT-001 is well-scoped: single mobile integration test, hermetic, mocked `apiClient`, asserts POST shape from `workers/worker/src/index.ts:242-252`.
- **A-03** MAJOR-03 (`services/index.ts` merge) genuinely solved by the marker-then-merge pattern in T-P3.6, not papered over. B-4 and B-5 batches updated to reflect this. T-P3.4 correctly carved out.
- **A-04** MAJOR-06 auth-gate signal verified live: `useAuthStore((s) => s.user && s.sessionToken ? s : null)` exists on `apps/mobile/lib/stores/authStore.ts` (L47/L54). `_layout.tsx` `hydrateAuth` call confirmed. Two-state mount test acceptance is the right design.
- **A-05** MINOR-05 `resumeMap` shape change to `Record<string, AnchorPoint>` is consistent across SPEC §3.11, §5.3, PLAN T-P1.6 (with JSON round-trip test) and T-P3.5 boundary adapter.
- **A-06** MINOR-02 JSON-parse failure case explicit in PLAN T-P1.3 acceptance criterion 4.
- **A-07** Phase 4 cleanly removed; no orphan tasks remain.
- **A-08** T-P5.2 subsumption is defensible — T-P3.4 produces the parity test; a separate Phase-5 entry would duplicate.
- **A-09** Open follow-ups in REVISION-NOTES are appropriately scoped (audit-only or future-issue) and do not need to land in this round.
- **A-10** Mapping table §6 is internally consistent: 11 IN-SCOPE + 6 DEFERRED + 3 DONE-on-main + 11 DONE/INFO covers all findings.

---

## Summary

| Severity | Count |
|---|---|
| BLOCKING | 0 |
| MAJOR | 0 |
| MINOR | 1 (file-count gate) |
| APPROVALS | 10 |

**Verdict: LOCK.** All three REVIEW-01 BLOCKERs are properly removed from in-scope and reclassified to §4 with verified file:line pointers; the new BILLING-AUDIT-001 is appropriately thin. All six REVIEW-01 MAJORs are addressed with concrete mechanisms (not wishful merges). All five REVIEW-01 MINORs are present in the revised documents.

One new MINOR remains: PLAN T-P3.1's voice-chat file-count gate cites two non-existent files (`billing.test.ts`, `usage-extract.ts`) and claims 19 — actual is 17 (9 source + 8 test). SPEC §3.3 has the same off-by-N issue ("8+6=14" / "~14 files"). The coder should be told the right number; otherwise the reviewer gate is unusable. This is documentation-only and does not affect any code path, so it does not block locking — fix in-flight during T-P3.1 execution by updating the gate count to 17.

**The spec and plan are ready to enter the red-phase.**

---

**End of REVIEW-02.md**
