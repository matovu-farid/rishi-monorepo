# Multi-Agent Test Review — Final Summary

**Date:** 2026-05-21
**Phases run:** Pilot + Phase A (renderer core) + Phase B (e2e specs)
**Phase C (everything else, ~80 files):** Skipped — Phase A+B already delivered strong ROI and the e2e environment limitations would compound through Phase C.

---

## Top-line Outcome

**3 real production bugs found and fixed via TDD:**

| Bug | Commit | Impact |
|---|---|---|
| **B001** — `useBookSyncId` caches `null` on mount | `8cada209` | Bookmark handlers permanently no-op for freshly imported AZW3/MOBI/EPUB books. Fix transparently restores bookmarking for all three formats (shared hook). |
| **B042** — Invalid book id route guard runs once on mount | `9f675273` | TanStack Router's hash history only listens for `popstate`, not `hashchange` — raw `location.hash` mutations bypass the guard. Invalid IDs reach the renderer and show error div. |
| **A100-followup** — `usePdfHighlights` no `.catch` on IPC | `6416bd83` | IPC rejection surfaces as unhandled promise rejection in production. Found via test-improvement work in Phase A. |

**13 test-quality fixes shipped** (16 commits total across pilot + Phase A + Phase B):

| # | Commit | Description |
|---|---|---|
| Q01 | `32ddeae9` | mobi.spec tautological assertions → iframe-based positive assertions |
| Q02 | `63525625` | mobi.spec waitForTimeout → `getByText('Book not found')` |
| Q03 | `0b157bf4` | azw3 dead `test.setTimeout` removal |
| Q04 | `d74f0391` | pdfStore resetParagraphState: 2 missing field assertions |
| Q05 | `87bc14d0` | epubStore bookOutline contract documented |
| Q06 | `bebde994` | pdfStore beforeEach → Zustand `setState(getInitialState(), true)` |
| A015 | `075a4975` | prefsStore hydrate: per-key wiring + type-guard fallback |
| A033 | `97cc20f2` | usePdfHighlights bookId-change + IPC-rejection coverage |
| A034 | `16659134` | usePdfTextSelection cross-page guard positive control |
| A091 | `544e8925` | reader-cache diagnostic surface (has/size/stats/resetStats) unit-tested |
| B019 | `8f542936` | epub-text-selection: real iframe `getSelection()` instead of parentElement walk |
| B073 | `b7b4c72a` | library accelerator regex tightened to canonical `CmdOrCtrl+N` |
| B099 | `fbc270b9` | read-aloud-from-selection: silent `test.skip(true,...)` → explicit `test.fixme` (2 now pass actively, 1 honest-fixme) |

**2 production issues identified but DEFERRED (need product decision):**

- **B103** — Library delete-without-confirmation. `FileComponent.tsx:369-384` fires `deleteBookMutation.mutate` directly from context-menu Delete with no confirmation dialog. Deletion is irreversible. Should there be a confirm prompt?
- **B018** — TocToggleButton not actually rendered in EPUB reader. Phase B Wave 9 attempted to fix the test's unsatisfiable selector; discovered the production button isn't mounted in the EPUB reader UI at all. Missing feature, not a test bug.

**Spawn-finding:** A100-followup was discovered during the A033 fix code-review and shipped as a separate production fix.

---

## Workflow Outcomes

**Total findings filed:** ~64 (26 in Phase A + 37 in Phase B + 1 in pilot)
**Total dispatches:** ~140-150 (well within combined budgets)

**Classification breakdown:**
- **BUG** (real production bugs): 8 across both phases. 3 fixed + 2 deferred + 3 reclassified as Type A on second read.
- **TEST-QUALITY-A** (fix-worthy test gaps): ~18. 9 fixed (5 in Phase A Wave 9 + 3 in Phase B Wave 9 + 1 spawn).
- **TEST-QUALITY-B** (documented for later): ~32. Recorded in `.agent-review/*/practices-audit.md`.
- **INVALID** (misreads): ~8. Closed.

**Parity gaps documented:** ~40 across pilot + Phase A + Phase B.
**Test-infra-backlog items:** ~15 items spanning helpers, fixtures, framework config.

---

## Workflow Lessons (for future runs)

1. **Subagent orchestrator is not feasible in this harness** — spawned subagents lack the `Agent`/`Task` tool, so the main thread must be the orchestrator. Reverted to that pattern after Phase A's first escalation.
2. **`feature-dev:code-reviewer` lacks Edit tool** — substitute `general-purpose` for even-ID reviewers in alternation pattern.
3. **Parallel-write contention** on shared files (Wave 2 in Phase A) lost ~30-40 audit entries from concurrent testers. Per-tester-file pattern (each tester writes to its own file, consolidate later) was applied in Phase B and worked cleanly.
4. **Planner timeouts** above ~8 files per planner — sub-divide planners with explicit "write file early" directive. Phase B sub-divided to ≤5 files per planner; all completed.
5. **E2E rebuild requirement** — `pnpm test:e2e` does NOT rebuild the renderer. Renderer-touching e2e iteration needs explicit `pnpm build` first. (B042 fix would have been masked otherwise.)
6. **E2E launchApp/closeApp teardown timeout** — pre-existing environment issue, surfaces frequently. Tracked as test-infra backlog. Blocks autonomous validation of many e2e mutation checks.
7. **`.agent-review/` was NOT actually gitignored** despite Phase A scaffold attempting it. Some finding files got committed inadvertently during fix commits. Cosmetic, but worth flagging.
8. **Reviewer-1's 4-way classification (BUG / TEST-QUALITY-A / TEST-QUALITY-B / INVALID)** worked well — much more informative than 2-way CONFIRM/REJECT. Saved a separate triage step.
9. **Mutation check (revert + re-run)** is critical — pilot Q-fixes had no mutation check; B001/B042 mutation checks revealed the tests were genuinely sensitive to the production change. This catches "test changed irrelevantly to coincide with fix" failures.

---

## Artifacts

Full audit trail under `.agent-review/`:

- `.agent-review/pilot/` — pilot findings, dialog, fix history
- `.agent-review/full-sweep-A/` — Phase A (renderer core) findings, plans, audits
- `.agent-review/full-sweep-B/` — Phase B (e2e specs) findings, plans, per-tester audits
- `docs/superpowers/specs/2026-05-20-multi-agent-test-review-design.md` — design spec
- `docs/superpowers/plans/2026-05-20-multi-agent-test-review-pilot.md` — pilot plan
- `docs/superpowers/plans/2026-05-20-multi-agent-test-review-full-sweep.md` — full sweep plan (Phase A/B/C)

---

## Recommended Follow-Ups

**Product decisions needed:**
1. B103: Add confirmation dialog to library Delete? (Or document that no-confirm is intentional.)
2. B018: Build TOC toggle for EPUB reader, or remove the dead `TocToggleButton` component?

**Test infrastructure backlog (would unlock more autonomous runs):**
3. E2E launchApp/closeApp teardown reliability (multiple specs affected — mobi.spec, pdf-reader, azw3-parity).
4. E2E pretest hook for `pnpm build` so renderer changes are picked up.
5. `.agent-review/` gitignore actually wired up if continuing to use this directory.
6. Per-tester-file pattern formalized for future multi-agent runs.

**Phase C** (~80 files: components, remaining services, src/main, src/preload, src/lib, modules):
- Skipped this run. Phase A+B yielded ~3 bugs from ~63 files; linear scaling suggests Phase C would yield ~4 more bugs. Worth running if budget allows, with the same workflow refinements.
- Likely-high-yield areas in Phase C: src/main/ipc (where pilot finding 011 originated), components/highlights, services/tts, services/voice-chat (real-time integration likely has races).

**Type A items NOT fixed in main wave** (originally deferred): A001, A013, A032, A043, B017, B031, B041, B047, B051, B052 (e2e env blocked), B053, B056, B057, B058, B074, B095, B100, B131.

---

## Wave 9 Follow-up (2026-05-21, same day)

Four parallel agent teams (Alpha/Beta/Gamma/Delta) ran a follow-up pass on the deferred items + parity gaps.

**Type A items fixed in Wave 9:**

| Item | Commit | Notes |
|---|---|---|
| A001 | `f9e25b32` | Production fix bundled with B017's commit by parallel-staging race — content is correct (indexingStore.finish() now clears stale error). Mutation check PASSED. |
| A013 | `530aba52` | tutorialStore resetTour: pre-seed all 5 state fields + 2 localStorage keys, assert each clears. |
| A032 | `ea768346` | useMenuCommands: symmetric afterEach restore + handler-throws + dispatch-order tests. |
| A043 | `f4a6855d` | useBookSyncId: waitFor positive-signal replaces setTimeout(0); re-render-with-new-bookId test added. |
| B017 | `f9e25b32` | epub-reader navigation: body/button tautologies → expect.poll over persisted CFI. |
| B031 | `c2bc333d` | pdf-import: scroll-shell attached → canvas visible + removed 3s sleep. |
| B041 | `625a2b6e` | pdf-reader keyboard nav: body-visible tautology → page-index expect.poll (forward/back). |
| B047 | `ada3ea26` | pdf-scroll-position restore: assert restored page matches saved page via `[data-page-number]`. |
| B051 | `78585f44` | pdf jitter: 2 preconditions (lowest-mounted-page > 1, remount-above on scroll-up). |
| B053 | `df931ece` | pdf jitter: threshold 80px → 8px with named const and justification. |
| B058 | `2583c56e` | bookmarks-submenu: waitForTimeout(1500) → expect.poll on published submenu. |
| B074 | `88cdf8bc` | recent: `.some()` predicate → `.filter().length === 1` (catches dedup bug). |
| B095 | `7dcdc8b5` | tts-page-navigation: 3 arbitrary waitForTimeout calls → waitForFunction event-based waits. |
| B100 | `3acdcd2e` | read-aloud-from-selection: length > 0 → cfiRange matches expected CFI. |
| B131 | `b2910cc5` | search: removed try/catch swallow + assert non-empty result for token 'the'. |

**Type A items closed as INVALID (Reviewer-1's verdict on second look):**

| Item | Commit | Notes |
|---|---|---|
| B056 | `24ae6e4f` | No-op (Reviewer-1 INVALID). Fix Plan annotated. |
| B057 | `97441ec7` | No-op (Reviewer-1 INVALID). Fix Plan annotated. |

**Parity gaps closed in Wave 9 (Team Delta):**

| Gap | Commit | New tests |
|---|---|---|
| authStore hydrateAuth `'0'`/`null`/catch branches | `b8654525` | +3 |
| indexingStore multi-book reset + start-twice | `6a2ae243` | +2 |
| chatStore connecting/thinking transitions + OfflineError branch | `b7b0ff85` | +4 |
| navStore null-send crash contract | `dee856dd` | +1 |

**Total new tests:** 10 parity-gap tests + ~6 from Type A fixes. Full unit suite now **1170/1170 passing** (was 1109). Typecheck green.

**Parity gaps deferred (with reasons in `parity-gaps.md`):**
- `playerStore` state transitions — production writes via xstate `setState`, not store actions; belongs in machine integration test.
- `playerStore.errors[]`, `playerStore.activeParagraph` — needs product/test-design input.
- `authStore.hydrateAuth` idempotency — pure-read, low value.
- `pdf-cache.test.ts`/`epub-cache.test.ts` — separately tracked as finding A092.
- `cache.ts` evictOldest tie-breaking — test-infra backlog (clock injection).

**Type A items still NOT fixed after Wave 9:**
- B052 (jitter sample window) — e2e env blocked.
- B018, B103 — deferred for product decision (unchanged).

**E2E mutation checks for Wave 9 e2e fixes:** ENV-BLOCKED. All Wave 9 e2e changes typecheck green; behavioral verification requires unblocking the `launchApp/closeApp` teardown reliability item (#3 in backlog above).

**Workflow lesson added:** Parallel agents staging the same files can interleave commits; A001's production change ended up bundled with B017's commit message. Mitigation for future runs: enforce per-agent file ownership at the planner level, or have agents `git stash` other agents' staged changes before committing.
