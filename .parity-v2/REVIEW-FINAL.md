# REVIEW-FINAL.md — Mobile/Electron Parity v2

**Review date:** 2026-06-04
**Reviewer scope:** SPEC §3.1..§3.11 (11 in-scope items) + MIGRATION-NOTES.md +
diff against `origin/main` (4 commits: spec/plan, red, green-P1+P2, green-P3).
**Test cost during review:** 0 commands (verified via existing reports in
MIGRATION-NOTES.md per token-discipline mandate).

---

## DELIVERED

| Spec item | Evidence |
|---|---|
| **BILLING-AUDIT-001** (§3.1) | Mobile integration test `apps/mobile/__tests__/integration/voice-chat-billing-wiring.test.ts:1-50` drives synthetic `response.done` + `close()`, asserts single POST to `/api/billing/realtime-usage`. (Note: SPEC named the file `apps/mobile/__tests__/voice-chat/billingReport.integration.test.ts` — actual lives under `__tests__/integration/`. Functional contract met; path drift is cosmetic.) |
| **BILLING-002** (§3.2) | Shared: `packages/shared/src/billing/errors.ts:12-40` (`BillingInactiveError` + `isInstance` cross-realm guard), `packages/shared/src/billing/interceptor.ts:21-46` (response.clone() + JSON parse failure → no-throw). Mobile: `apps/mobile/lib/api.ts:79-99` (interceptor + store wiring), `apps/mobile/lib/stores/billingStore.ts`, `apps/mobile/components/billing/BillingInactiveModal.tsx`, `apps/mobile/app/_layout.tsx:229,248` (modal mounted at root in both E2E and prod branches). Tests: `__tests__/api/billing-gate.test.ts`, `__tests__/components/BillingInactiveModal.test.tsx`, `packages/shared/src/billing/interceptor.test.ts` (incl. MINOR-02 'not-json' case). |
| **DRY-001** (§3.3) — voice-chat | `apps/rishi-electron/src/renderer/src/services/voice-chat/` deleted (19 files per MIGRATION-NOTES T-P3.1). `services/index.ts:13,259-396` imports from `@rishi/shared/voice-chat`, supplies `captureError: sentryCaptureError` (line 264) and `billing: { apiFetch: workerFetch }` (line 263). `grep` confirmed: zero `@/services/voice-chat` or `./voice-chat` imports remain. |
| **DRY-002** (§3.4) — TTS | `apps/rishi-electron/src/renderer/src/services/tts/{service,program,cache,emitter,errors,types,visual-cue-emitter}.ts` deleted. `tts/index.ts` is now a thin re-export shim around `@rishi/shared/tts` (`apps/rishi-electron/src/renderer/src/services/tts/index.ts:7-33`). `linkOrCopyFile` IPC wired at `services/index.ts:117`. |
| **DRY-003** (§3.5) — book-import | **DELIBERATELY SCOPED OUT** — see DEFERRED section below. Documented in `.parity-v2/MIGRATION-NOTES.md` lines 70-133 with concrete divergence enumeration. |
| **DRY-004** (§3.6) — prompt helpers | `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts` — inline `renderOutlineSection`/`renderActiveParagraphSection`/`renderVisualSection`/`INSTRUCTIONS_TEMPLATE` (~95 LoC) deleted, replaced by `renderRealtimeInstructions` from `@rishi/shared/voice-chat/build-realtime-agent`. Parity test: `packages/shared/__tests__/prompt-parity.test.ts` (191 lines). |
| **DRY-005** (§3.7) — chunk-ID parity | `packages/shared/__tests__/chunk-id-parity.test.ts:102,128` is **`test.fails(...)`** as required by SPIKE-OUTCOMES Verdict D. Confirms divergence still documented (electron positional vs mobile content-addressable). Spike doc `.parity-v2/CHUNK-ID-SPIKE.md` enumerates the algorithms and proposed alignment. |
| **CONTEXT-001** (§3.8) — page text | Shared helper: `packages/shared/src/voice-chat/pageTextCap.ts:34-80` (paragraph → sentence → word → hard-cut fallback). Four per-reader extractors: `apps/mobile/lib/voice-chat/pagetext/{epub,pdf,mobi,djvu}.ts` — all wrap try/catch, all apply `softCapPageText(text, 8000)`, all return `''` on missing/error and NEVER fall back to placeholder strings. Tests: `__tests__/voice-chat/activation-context-pagetext.test.ts`, `__tests__/lib/voice-chat/softCapPageText.test.ts`. Reader files updated: `app/reader/[id].tsx`, `app/reader/pdf/[id].tsx`, `app/reader/mobi/[id].tsx`, `app/reader/djvu/[id].tsx`. |
| **WIRING-001** (§3.9) — `setChatVoicePort` | `apps/mobile/lib/voice-chat/startup-wiring.ts:39-68` (module-level `wired` flag + auth subscription, idempotent; `_resetStartupWiringForTests` exposed). `buildService.ts:21-23` is the factory hook. Mounted from `app/_layout.tsx:138-147` in `.finally()` of `hydrateAuth`, wrapped in try/catch. Test: `__tests__/integration/voice-chat-wiring.test.ts`. |
| **NAVHIST-001** (§3.11) — navigation history | Shared machine: `packages/shared/src/machines/navigationHistory/{navigationHistoryMachine,types,pageKey,index}.ts`. **`resumeMap: Record<string, AnchorPoint>`** (per MINOR-05) — see `navigationHistoryMachine.ts:19-26`. Mobile binding: `apps/mobile/lib/machines/navigationHistory/index.ts:36-37` (module-scoped actor). UI: `apps/mobile/components/reader/NavBackPill.tsx` (Reanimated FadeIn/FadeOut). Electron migrated: `machines/navigationHistory/types.ts` is now a re-export shim, `navigationHistoryActor.ts:3` imports `navigationHistoryMachine` from shared. Closes R-007 as byproduct. Tests: `packages/shared/src/machines/navigationHistory/navigationHistoryMachine.test.ts` (incl. JSON round-trip), `apps/mobile/__tests__/components/reader/NavBackPill.test.tsx`, `__tests__/lib/voice-chat/navigation-history-actor.test.ts`. |

---

## DEFERRED (with documented reason)

| Spec item | Deferral note |
|---|---|
| **VAD-001** (§3.10) | `.parity-v2/VAD-001-investigation.md` (27 lines) — BRANCH B per SPEC §3.10 criterion 5. Blocker is upstream: `react-native-audio-api@0.12.2` does not implement `createMediaStreamSource` (Software Mansion #872, maintainer targeting 0.13) and `react-native-webrtc@124.0.7` exposes no raw PCM. `.parity-v2/VAD-SPIKE.md` carries the full compatibility matrix. Spec §3.10 criterion 5 (criteria-5 deferral path) is satisfied. |
| **DRY-003** (§3.5) | `.parity-v2/MIGRATION-NOTES.md` lines 70-133 — concrete enumeration of 5 deep divergences (service shape, scanner/DiscoveryEvent, indexer port asymmetry, importer hash stage, event shape). An adapter would be ~300–500 LoC and require re-emitting electron's `hashing`/`duplicate` progress events that shared dropped. Recommended follow-up: realign book-import in a dedicated phase. |
| **DRY-005 (T-P5.1)** | Indirectly deferred by DRY-003 — the chunk-ID parity assertion that depended on the adapter is replaced by the inline `test.fails(...)` regression marker per Verdict D. The test ships and stays red until algorithms align. |

---

## BLOCKING

**None.** All 11 in-scope items either ship as DELIVERED or have a documented deferral note. The two deferrals (VAD-001, DRY-003) carry standalone investigation/migration markdown files in `.parity-v2/`. No silent gaps.

---

## MAJOR (real bugs; ≥80% confidence)

**None observed.** Spot-checks of 5 files (`packages/shared/src/billing/interceptor.ts`, `packages/shared/src/voice-chat/pageTextCap.ts`, `packages/shared/src/machines/navigationHistory/navigationHistoryMachine.ts`, `apps/mobile/lib/api.ts`, `apps/mobile/lib/voice-chat/startup-wiring.ts`) and 4 supporting files (`apps/mobile/lib/voice-chat/pagetext/{epub,pdf,mobi,djvu}.ts`) surfaced no NPEs, off-by-one, race conditions, or wrong-API usage.

Notable correctness-positive observations:

- `BillingInactiveError.isInstance` (errors.ts:32-39) duck-typed check + `Object.setPrototypeOf` (errors.ts:25) handle cross-realm boundaries — useful when the error crosses jsdom ↔ node boundaries in tests.
- `checkBillingGate` (interceptor.ts) correctly **clones** the response before reading, so non-matching 402s remain readable to callers.
- `runStartupWiring` (startup-wiring.ts) guards re-entry: module-level `wired` flag + `unsubscribe` guard prevents stacked subscriptions across hot-reloads.
- All four per-reader pagetext extractors wrap in try/catch and return `''` on failure rather than throwing into the activation context.
- The mobile pagetext extractors never fall back to placeholder strings ("Chapter N" / "Page N of M") — the original bug per SPEC §3.8 is fixed by construction.
- The shared `navigationHistoryMachine` `emitPopAnchorAsResume` action runs BEFORE `popAnchor` (machine line 158) — comment explicitly cites the invariant. Without that ordering the pill click "succeeds" but the user stays on the page they jumped TO.

---

## MINOR (cleanup / nit)

1. **Test file path drift (SPEC vs reality).** SPEC §3.1 names the BILLING-AUDIT-001 test as `apps/mobile/__tests__/voice-chat/billingReport.integration.test.ts`; actual file is `apps/mobile/__tests__/integration/voice-chat-billing-wiring.test.ts`. Same applies to several other test files. Functional contract met; consider a path-rename pass if the SPEC is to remain authoritative.

2. **`softCapPageText` signature divergence.** SPEC §3.8 specifies `softCapPageText(text: string, max: number = 8000): string` (default arg). Actual signature requires `cap` as a positional arg (`packages/shared/src/voice-chat/pageTextCap.ts:36`). All four mobile pagetext extractors pass `PAGE_TEXT_CAP = 8000` explicitly, so the SPEC's intent (8000 default) is preserved through callers. Optional: add `cap: number = 8000` to the shared helper to match SPEC verbatim.

3. **Stale task-list entry.** Top-level task #13 ("T-P3.3: book-import DRY migration with adapter") is marked `completed`, but the task was explicitly scoped out (MIGRATION-NOTES T-P3.3 — STATUS: deferred). Task-list bookkeeping only; no functional impact.

4. **Module-scoped XState actor at import time.** Both `packages/shared/src/machines/navigationHistory` (via mobile consumer `lib/machines/navigationHistory/index.ts:36-37`) and electron's `navigationHistoryActor.ts:6-7` create + start the actor at module import. This matches the pre-existing electron pattern and is intentional, but watch for it in any future SSR / hot-reload migration.

5. **`buildRealtimeAgent.ts:100` comment.** A code comment in `modules/buildRealtimeAgent.ts:100` still references the pre-DRY-001 `services/voice-chat/` path. Comment-only — no compile or runtime effect. Drop on next touch.

6. **MIGRATION-NOTES "mobile jest pending".** The mobile jest run is documented as "pending" in MIGRATION-NOTES table. Per the reviewer's mandate I did not re-run tests; this should be flipped to green before merge by the coder closing out task #10.

---

## APPROVALS

- **Spec coverage:** 11/11 in-scope items DELIVERED or DEFERRED with documented reason. No BLOCKING gap.
- **Diff correctness:** 9 spot-checked files clean. No NPE / race / wrong-API hits.
- **Test coverage:** behaviour-asserting (length checks, instance checks, JSON round-trip, dedup, "NEVER fall back to placeholder" negative assertions). Mocks reasonable; no obvious masking.
- **xstate alignment:** `^5.30.0` across shared / mobile / electron — earlier 5.31.1/5.32.0 mismatch is resolved.
- **`services/index.ts`:** zero `PARITY-V2-MARKER` strings remain; imports clean; `captureError` + `billing.apiFetch` + `linkOrCopyFile` all supplied.
- **Electron deletions safe:** zero remaining `@/services/voice-chat` or `./voice-chat` imports; `services/voice-chat/` directory gone; `services/tts/` reduced to re-export shim + electron-specific resolve-paragraph wrapper.
- **DRY-005 chunk-ID parity:** test is still `test.fails(...)` per Verdict D (lines 102, 128 of `chunk-id-parity.test.ts`) — not regressed to a real pass.
- **VAD-001 closure:** `.parity-v2/VAD-001-investigation.md` present and references `VAD-SPIKE.md`. Spec §3.10 criterion 5 satisfied.

---

## VERDICT

**SHIP**

Caveats for the finalize-and-commit step (task #10):
1. Run mobile jest and verify green before tagging the PR.
2. Optional: add `cap = 8000` default arg to `softCapPageText` to match SPEC verbatim (1-line change; behaviour identical at all current call sites).
3. Optional: refresh task #13 status from "completed" → "deferred (scoped out)" so the task list stays trustworthy.
4. PR body should cite `.parity-v2/MIGRATION-NOTES.md` T-P3.3 deferral and `.parity-v2/VAD-001-investigation.md` so future researchers don't re-open the items.
