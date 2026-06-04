# REVIEW-01.md — Parity v2 Spec + Plan Audit

**Reviewer:** spec+plan reviewer
**Review date:** 2026-06-04
**Documents audited:** `.parity-v2/RESEARCH.md`, `.parity-v2/SPEC.md`, `.parity-v2/PLAN.md`
**Verdict:** REVISE

---

## BLOCKING

### BLOCKING-01: BILLING-001 is already implemented on both clients — SPEC and PLAN are rebuilding working code

RESEARCH.md states `apps/mobile/lib/voice-chat/realtime-session.ts:276-278` is `case 'response.done': emit('agent_end') break` — an unimplemented billing site. SPEC §3.1 and PLAN T-P2.2 both depend on this being true.

**Actual state of the file:**
- `realtime-session.ts:280-298` — `case 'response.done'` is fully implemented: extracts `input_token_details` / `output_token_details`, calls `usage.add(...)` via `createUsageAccumulator`, emits `agent_end`. (`realtime-session.ts:48-49` imports `createUsageAccumulator` from `@rishi/shared/billing/realtime-usage-accumulator` and `reportRealtimeUsage` from `@rishi/shared/billing/realtime-usage-client`.)
- `realtime-session.ts:364-374` — `close()` calls `usage.flush()` then `void reportRealtimeUsage(apiClient, total)` — fire-and-forget.
- `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts:14` — electron already imports `reportRealtimeUsage`.
- `apps/rishi-electron/src/renderer/src/services/index.ts:262` — electron wires `billing: { apiFetch: workerFetch }` into voice-chat.
- `packages/shared/src/billing/realtime-usage-accumulator.ts` and `realtime-usage-client.ts` — EXIST with full test coverage (`realtime-usage-client.test.ts`).
- `packages/shared/package.json:66-67` — both modules in `exports` map.

The "revenue leak" in `BILLING-HANDOFF.md` has been closed since the research snapshot. SPEC's BILLING-001 (adding `VoiceChatIpc.reportUsage`) would create a THIRD billing implementation, causing duplicate POSTs on mobile.

**Recommendation:** Remove BILLING-001 from in-scope. Replace with a thin gap-confirmation audit task verifying the existing wiring is integration-tested. Update RESEARCH→SPEC mapping. Mark B-001/B-002/B-003/T-003 as DONE.

---

### BLOCKING-02: EBUG-FIX-001 targets a function that does not exist in the cited file

SPEC §3.10 and PLAN T-P4.1 cite `workers/worker/src/billing/stripe.ts:21-42` as containing `applyWelcomeCreditAndSubscription` with no idempotency guard.

**Actual state:**
- `workers/worker/src/billing/stripe.ts` — contains only `createStripeClient` (16 lines). No `applyWelcomeCreditAndSubscription`.
- The actual function is `ensureCreditAndSubscription` in `workers/worker/src/billing/backfill.ts:31-85`. It checks `customer.balance <= -WELCOME_CREDIT_CENTS` and lists subscriptions to skip duplicates.
- `workers/worker/src/auth.ts:10,80-85` — `onCustomerCreate` calls `ensureCreditAndSubscription` from `billing/backfill.ts`.
- `workers/worker/src/billing/backfill.test.ts:491-508` — idempotency is ALREADY tested.

Research finding D-006 was incorrect. EBUG-001 is already fixed.

**Recommendation:** Remove EBUG-FIX-001. Mark D-006/EBUG-001 as DONE. Delete T-P4.1.

---

### BLOCKING-03: BILLING-003 (Customer Portal link) is already implemented on both clients

RESEARCH.md D-005 says no link/button exists in mobile or electron settings.

**Actual state:**
- `apps/mobile/app/(tabs)/settings/index.tsx:67-175` — `handleManageBilling` POSTs to `/api/billing/portal`, opens with `WebBrowser.openBrowserAsync`. Button at line 165-175.
- `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx:37-118` — same pattern with `workerFetch`. Button at line 114-118.
- `account.test.tsx:40,52` — covers click → POST → open URL.

**Recommendation:** Remove BILLING-003. Mark D-005 as DONE. Add a tiny test-presence check on mobile if missing (MINOR follow-up).

---

## MAJOR

### MAJOR-01: BILLING-001 SPEC's `VoiceChatIpc.reportUsage` design would cause duplicate POSTs and break `mobileVoiceChatIpc`
SPEC §3.1 makes `reportUsage` a **required** field on `VoiceChatIpc` (`packages/shared/src/voice-chat/types.ts:143-152`). `apps/mobile/lib/voice-chat/ipc.ts:9-46` implements `VoiceChatIpc` without it — making this required would TS-fail mobile immediately. Moot if BLOCKING-01 is accepted.

### MAJOR-02: SPEC §3.1 cites `workers/worker/src/billing/realtime-usage.ts` as the body shape authority — file may not exist
The actual endpoint body handling appears inline in `workers/worker/src/index.ts:242-252`. Verify and correct.

### MAJOR-03: Phase 3 parallelization unsafe — T-P3.1/T-P3.2/T-P3.3 and T-P4.2 all modify `apps/rishi-electron/src/renderer/src/services/index.ts`
Parallel agents will conflict on this single wiring file. Sequence or batch the `services/index.ts` edits into one sub-task.

### MAJOR-04: EBUG-FIX-001 description-string match is fragile (moot per BLOCKING-02, recorded for completeness)
If reopened, the deployed `customer.balance <= -WELCOME_CREDIT_CENTS` approach is more robust than string matching.

### MAJOR-05: T-P1.1 contradicts §5.3 "non-breaking" — `reportUsage` as REQUIRED is breaking
Should be optional in Phase 1 if it proceeds; or land atomically with consumers. Moot per BLOCKING-01.

### MAJOR-06: WIRING-001 (T-P2.1) — no auth-race guard specified
SPEC §3.11 doesn't name the exact Better Auth signal (`useSession().data !== null`?) to gate service construction on. A coder will guess. Name the signal in the spec; assert it in the test.

---

## MINOR

### MINOR-01: CONTEXT-001 reader file paths — all 4 verified correct
- `apps/mobile/app/reader/[id].tsx:761` ✓
- `apps/mobile/app/reader/pdf/[id].tsx:700-704` ✓
- `apps/mobile/app/reader/mobi/[id].tsx:699` ✓
- `apps/mobile/app/reader/djvu/[id].tsx:577-581` ✓

### MINOR-02: BILLING-002 (402 interceptor) — missing test for `status: 402, body: 'not-json'` (JSON parse failure)
Interceptor must return normally on JSON parse error for non-BILLING_INACTIVE 402s.

### MINOR-03: DRY-001 (T-P3.1) reviewer gate cites 14 files (8 source + 6 test); actual directory has 17 (8 source + 8 test + 1 index). Fix deletion-audit count.

### MINOR-04: Phase 0 spike T-P0.3 still needed for DRY-005 chunk-ID parity even after blocker removals.

### MINOR-05: NAVHIST-001 (T-P1.6) — `Map<string, AnchorPoint>` in XState context is not JSON-serializable
Replace with `Record<string, AnchorPoint>` before lifting to shared to keep devtools/inspectors working. Note in T-P1.6 reviewer focus.

---

## APPROVALS

- **A-01** Deferred items are all defensible (D-001 P2P, G-002 page-curl, G-005 cover UX, G-009 chime, R-007/R-008).
- **A-02** DRY-001/002/003/004 are real, correctly scoped. Electron `services/voice-chat`, `services/tts`, `services/book-import` are largely local copies; `buildRealtimeAgent.ts:114-158` inline helpers confirmed.
- **A-03** BILLING-002 (402 interceptor + modal) is genuinely unimplemented. `packages/shared/src/billing/` has no `errors.ts`/`interceptor.ts`. Proceed as specified.
- **A-04** CONTEXT-001 is correctly scoped; all 4 reader file paths real.
- **A-05** VAD-001 investigation-gate is correct, not lazy.
- **A-06** WIRING-001 — confirmed: `grep -r "setChatVoicePort" apps/mobile/app` returns nothing.
- **A-07** DRY-003 adapter approach is right call (BookId=number parametric mismatch).
- **A-08** Phase 1 parallelization is safe across the actual files (when BLOCKING items are removed).
- **A-09** Risk R2/R3 identification and mitigation are concrete.
- **A-10** TDD discipline is maintained; every task lists red-phase test.

---

## Summary

| Severity | Count |
|---|---|
| BLOCKING | 3 |
| MAJOR | 6 |
| MINOR | 5 |
| APPROVALS | 10 |

**Verdict: REVISE.** Three blockers — all caused by the research snapshot being taken before the recent billing-wiring commits (`9a766143`, `88ca71df`, `d5ac52fc`, `d7aa59cf`) landed. After removing BILLING-001, BILLING-003, EBUG-FIX-001, the in-scope shrinks to 10 items (BILLING-002, DRY-001..004, DRY-005, CONTEXT-001, WIRING-001, VAD-001, NAVHIST-001) and the plan shrinks from 26 tasks to ~18. Remaining 10-item plan is sound after MAJOR/MINOR fixes.
