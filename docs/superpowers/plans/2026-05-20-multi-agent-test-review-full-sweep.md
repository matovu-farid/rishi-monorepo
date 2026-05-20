# Multi-Agent Test Review — Full Sweep (Tiered) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (main thread is the orchestrator; subagent-orchestrator design proven infeasible during pilot). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Apply the multi-agent test-review workflow to the rest of the apps/rishi-electron test suite (~154 files outside the pilot scope), tiered into three phases with explicit human go/no-go between phases.

**Architecture:** Identical to the pilot's wave model (see `2026-05-20-multi-agent-test-review-pilot.md` for the role prompts and wave mechanics). Main thread dispatches workers; INDEX.md is the resumable state file. Sequential fix waves remain sequential. Per-finding cap stays at 8.

**Tech Stack:** Same as pilot.

**Spec reference:** `docs/superpowers/specs/2026-05-20-multi-agent-test-review-design.md`
**Pilot plan reference (waves are inherited):** `docs/superpowers/plans/2026-05-20-multi-agent-test-review-pilot.md`
**Pilot results / lessons:** `.agent-review/pilot/INDEX.md`

---

## Pilot Lessons Applied

These four adjustments come from the pilot's final `INDEX.md`:

1. **Planner pre-screens `test.skip(...)` specs.** Skipped tests cannot expose bugs (they don't run). The planner produces a "skip list" — those files go straight to `parity-gaps.md` as "skipped — should-be-unskipped" entries, and testers don't waste dispatches looking for findings in them.
2. **Triager checks project-level config before claiming spec-level impact.** Q03 lesson: removing a per-spec `test.setTimeout(N)` is a no-op if `playwright.config.ts` already sets the same N. Same applies to vitest config, jest config, etc. The Wave 8 triager reads project configs first.
3. **Reviewer alternation stays as-is** (odd ID → `team-reviewer`, even ID → `feature-dev:code-reviewer`). Pilot had n=1 so we couldn't measure value; only meaningful at scale.
4. **New artifact: `test-infra-backlog.md`.** Issues that span multiple test files and need real infrastructure work (e.g., the orphan `BrowserWindow` teardown timeout in `mobi.spec.ts`) get their own category — not findings, not Type A test-quality, not parity gap. Documented for follow-up.

---

## Tiered Structure

| Phase | Files | Est. dispatches | Notes |
|---|---|---|---|
| **A — Renderer core** | 37 (stores, machines, hooks, book-import, indexing, connectivity, reader-cache) | ~120-150 | Highest bug-yield surface. Run first. |
| **B — E2E specs** | 35 (all e2e/*.spec.ts except the 4 pilot specs) | ~120-180 | Slowest tests, highest user-impact bugs. Run after Phase A go/no-go. |
| **C — Everything else** | ~80 (components, remaining services, src/main, src/preload, src/lib, modules) | ~200-300 | Long tail. Run after Phase B go/no-go. |

**Go/no-go between phases:** main thread presents Phase X's INDEX.md to the human. Human decides whether Phase X+1 runs, and if so whether scope shrinks. This prevents committing autonomously to >500 dispatches.

---

## Phase A — Renderer Core

### A.1 Scope (37 files)

**Stores (10):**
- `src/renderer/src/stores/authStore.test.ts`
- `src/renderer/src/stores/chatStore.test.ts`
- `src/renderer/src/stores/epubStore.test.ts` (touched in pilot Q05; re-include — different test scope)
- `src/renderer/src/stores/indexingStore.test.ts`
- `src/renderer/src/stores/navStore.test.ts`
- `src/renderer/src/stores/pdfStore.test.ts` (touched in pilot Q04/Q06; re-include)
- `src/renderer/src/stores/playerStore.test.ts`
- `src/renderer/src/stores/prefsStore.test.ts`
- `src/renderer/src/stores/selectionStore.test.ts`
- `src/renderer/src/stores/tutorialStore.test.ts`

**Machines (4):**
- `src/renderer/src/machines/__tests__/connectivityMachine.test.ts`
- `src/renderer/src/machines/pdfReaderMachine.test.ts`
- `src/renderer/src/machines/playerMachine.recovery.test.ts`
- `src/renderer/src/machines/playerMachine.test.ts`

**Hooks (12):**
- `src/renderer/src/hooks/useMenuCommands.test.ts`
- `src/renderer/src/hooks/usePdfHighlights.test.tsx`
- `src/renderer/src/hooks/usePdfReadAloudFromSelection.test.tsx`
- `src/renderer/src/hooks/usePdfTextSelection.test.tsx`
- `src/renderer/src/hooks/useTtsHighlightReconciler.test.ts`
- `src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx`
- `src/renderer/src/hooks/reader/__tests__/useBookEmbeddings.test.ts`
- `src/renderer/src/hooks/reader/__tests__/useBookSyncId.test.ts`
- `src/renderer/src/hooks/reader/__tests__/useChapterParagraphPrefetch.test.ts`
- `src/renderer/src/hooks/reader/__tests__/useCommonMenuHandlers.test.ts`
- `src/renderer/src/hooks/reader/__tests__/usePageRequestSubscription.test.ts`
- `src/renderer/src/hooks/reader/__tests__/useReaderMenuSync.test.ts`

**Services subset (11):**
- `src/renderer/src/services/book-import/dispatch.test.ts`
- `src/renderer/src/services/book-import/emitter.test.ts`
- `src/renderer/src/services/book-import/importer.test.ts`
- `src/renderer/src/services/book-import/indexer.test.ts`
- `src/renderer/src/services/book-import/scanner-adapter.test.ts`
- `src/renderer/src/services/book-import/service.test.ts`
- `src/renderer/src/services/connectivity/service.test.ts`
- `src/renderer/src/services/connectivity/subscribers.test.ts`
- `src/renderer/src/services/connectivity/types.test.ts`
- `src/renderer/src/services/indexing/index-program.test.ts`
- `src/renderer/src/services/indexing/text-extraction.test.ts`
- `src/renderer/src/services/reader-cache/cache.test.ts`

### A.2 Wave structure (Phase A)

Same wave model as pilot. Differences from pilot scaling:

- **Wave 0 (Setup):** scaffold `.agent-review/full-sweep-A/` with the same subdirs. INDEX.md uses the same template.
- **Wave 1 (Plan):** dispatch **4 planners in parallel** — one per area cluster: (1) stores, (2) machines+hooks, (3) book-import services, (4) connectivity+indexing+reader-cache. Each produces `plan-<area>.md`. Each planner explicitly produces a "skip list" of `test.skip(...)` files in their area.
- **Wave 2 (Triage):** dispatch **10 testers in parallel**, batched by area: 2 for stores, 2 for machines+hooks, 2 for book-import, 1 for connectivity, 1 for indexing, 1 for reader-cache, 1 wildcard for cross-cutting findings. Each tester gets an ID range of 10 to avoid clobbering. Max 5 findings per tester. **Skipped tests do NOT count toward findings; they auto-go to parity-gaps.**
- **Waves 3-5 (Review / Rebuttal / Tiebreaker):** as pilot, parallel per-finding.
- **Triage gate (between waves 5 and 6):** main thread presents `INDEX.md` to human. Human selects which CONFIRMED findings get fixed this run. Reason: Phase A may surface 10-30 confirmed bugs; you may want to scope.
- **Wave 6 (Fix bugs):** sequential per confirmed bug, user-selected subset only.
- **Wave 7 (Mutation check):** sequential per fixed bug.
- **Wave 8 (Test-quality triage):** as pilot, with the project-config check baked in.
- **Wave 9 (Test-quality fix):** sequential per Type A item. Budget: ≤12 Type A items for Phase A (more would push budget too high).
- **Wave 10 (Summary):** updates INDEX.md, surfaces results, and asks human go/no-go on Phase B.

### A.3 Budget (Phase A)

- Soft cap: 150 dispatches
- Per-finding cap: 8 (unchanged)
- Triage gate prevents fix-budget explosion (you decide scope)

### A.4 Resumability

Same as pilot. INDEX.md's wave-status + per-finding stage columns let any future session pick up. If main-thread context fills, summarize the run, commit work-in-progress, resume in a fresh session by reading INDEX.md.

---

## Phase B — E2E Specs (after Phase A go/no-go)

### B.1 Scope (35 files)

All `e2e/*.spec.ts` EXCEPT the 4 pilot specs:
- `pdf-warm-restore.spec.ts` (pilot)
- `epub-warm-restore.spec.ts` (pilot)
- `azw3-real-import-routing.spec.ts` (pilot)
- `mobi.spec.ts` (pilot)

Phase B specs include: ai-chat, auth, azw3-*, epub-*, import, library, menu-*, mobi-global-page-counter, no-toolbar, pdf-*, read-aloud-from-selection, scanner, search, smoke, tts*, tutorial, window-split.

### B.2 Wave structure (Phase B)

Same as Phase A. Differences:
- **Wave 1:** 4 planners by area — (1) format-specific specs (azw3/epub/mobi/pdf), (2) menu-* specs, (3) feature specs (ai-chat, tts, search, tutorial, scanner, read-aloud-from-selection), (4) infra specs (auth, import, library, smoke, no-toolbar, window-split).
- **Wave 2:** 12 testers parallel. Each gets ~3 specs.
- **Build prerequisite:** every reviewer/coder dispatch must verify `out/main/index.js` exists before running e2e; rebuild if not. Add to all e2e-touching prompts (planner emits this reminder).
- **Per-spec wall-clock cost:** e2e specs take 10s-60s each to run; reviewer-1 flake checks (3 runs) get expensive. **Adjust flake check to 2 runs for e2e specs** to keep budget reasonable. Note this in the reviewer-1 prompt for Phase B.

### B.3 Budget (Phase B)

- Soft cap: 180 dispatches
- Triage gate before Wave 6

---

## Phase C — Everything Else (after Phase B go/no-go)

### C.1 Scope (~80 files)

Components, remaining services (tts, voice-chat, sync, rag), src/main (auth, ipc, menu, vectordb, windows), src/preload, src/lib, src/renderer/src/modules, src/renderer/src/pdf, src/renderer/src/components.

### C.2 Wave structure (Phase C)

Same as Phase A. 5-6 planners by area; 15-18 testers parallel.

### C.3 Budget (Phase C)

- Soft cap: 300 dispatches
- Triage gate before Wave 6
- **If global Phase A+B+C dispatch count exceeds 500: escalate to user before continuing.**

---

## Final Summary (after Phase C or after early stop)

Aggregate findings across phases. Produce a top-level `.agent-review/full-sweep/SUMMARY.md` that pulls from each phase's INDEX.md. Sections:

- Total bugs confirmed / fixed / unfixed-but-tracked
- Total Type A test-quality items fixed
- Top parity gaps across formats
- Test-infra backlog (`test-infra-backlog.md` consolidated)
- Workflow health signals (reviewer split, tiebreaker overturn rate, calibration)
- Recommendations for ongoing test discipline

---

## What This Plan Does Not Cover

- Mobile or web (per repo convention).
- Test infrastructure rewrites (those go in `test-infra-backlog.md` for separate planning).
- New test frameworks or runners.
- Production-code changes beyond what individual fixes require.
- The pilot's 7 files — already covered (re-included where the audit indicates an unmet contract, e.g., Phase A re-tests `pdfStore.test.ts` because Q04/Q06 didn't exhaust its audit surface).
