# Phase B (E2E Specs) — Test Review Index

## Wave Status

| Wave | Status | Started | Completed |
|---|---|---|---|
| 0. Setup | done | 2026-05-21 | 2026-05-21 |
| 1. Plan (8 sub-planners ≤5 files each) | done | 2026-05-21 | 2026-05-21 |
| 2. Triage (10 testers parallel, per-tester files) | done (37 findings, 9/10 testers wrote audit files cleanly — per-tester pattern WORKED) | 2026-05-21 | 2026-05-21 |
| 2.5. Consolidate per-tester audit files | deferred to Wave 10 | | |
| 3. Reviewer-1 (4-way classification) | in-progress (37 findings, 4 batches) | 2026-05-21 | |
| 4. Rebuttal | pending | | |
| 5. Tiebreaker | pending | | |
| 5.5. Triage gate (autonomous selection) | pending | | |
| 6. Fix (bugs) | pending | | |
| 7. Mutation check | pending | | |
| 9. Test-quality fix (top items) | pending | | |
| 10. Summary | pending | | |

## Phase A lessons applied

1. **Per-tester audit files** in `per-tester/` directory. Each tester writes `parity-gaps-T<N>.md`, `practices-audit-T<N>.md`, `test-infra-T<N>.md`. Consolidator (Wave 2.5) merges to root-level files.
2. **General-purpose for even-ID reviewers** (feature-dev:code-reviewer lacks Edit tool).
3. **Sub-planner scope ≤5 files** with write-file-early directive.
4. **E2E reality:** every coder/reviewer dispatch must check `out/main/index.js` exists before running tests. Flake check 2 runs (not 3) due to e2e slowness.

## Planner assignments (8)

| Planner | Files | Plan output |
|---|---|---|
| P1 | AZW3 (4): azw3-column-alignment, azw3-open, azw3-parity, azw3-render-content | plan-azw3.md |
| P2 | EPUB (4): epub-cache-no-flash, epub-first-open, epub-reader, epub-text-selection | plan-epub.md |
| P3 | PDF-A (3): pdf-import, pdf-persistence, pdf-reader | plan-pdf-A.md |
| P4 | PDF-B (2): pdf-scroll-position, pdf-scroll-up-jitter | plan-pdf-B.md |
| P5 | Menu-A (3): menu-book-epub, menu-book-pdf, menu-bookmarks-submenu | plan-menu-A.md |
| P6 | Menu-B (3): menu-commands, menu-library, menu-recent | plan-menu-B.md |
| P7 | TTS/Chat (4): ai-chat, tts, tts-page-navigation, read-aloud-from-selection | plan-tts-chat.md |
| P8 | Infra (5): auth, import, library, smoke, no-toolbar + Misc (4): mobi-global-page-counter, scanner, search, tutorial, window-split | plan-infra-misc.md |

## Findings

| ID | Spec | Current Stage | Reviewer-1 Outcome | Tiebreaker | Fix Commit | Mutation Passed | Dispatches Used |
|---|---|---|---|---|---|---|---|

## Dispatch Budget
- Phase B soft cap: 180 dispatches
- Per-finding cap: 8
- Current global count: 18 (8 planners + 10 testers)
