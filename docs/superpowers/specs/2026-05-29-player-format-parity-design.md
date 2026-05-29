# Player format parity — finishing the Phase 3 actor restructure

**Date:** 2026-05-29
**Scope:** apps/rishi-electron (Rishi Electron renderer)
**Origin:** PR #252 ("Phase 3 player-actor restructure + auto-advance race fixes") landed the new architecture but left half the migration in place. PDF still has a user-visible regression: when the last paragraph of a page finishes, audio stops instead of advancing to the next page.

## Problem

The user perceives "a lot of variance between EPUB and PDF" in the TTS player. PR #252 was meant to eliminate that variance by introducing a shared protocol (the view-actor protocol in `src/renderer/src/actors/viewActor.ts`) and per-format implementations (`epubViewActor`, `pdfViewActor`). The protocol exists and is partly wired, but the migration is incomplete. The leftover seams produce format-specific bugs that the protocol was designed to prevent.

## Current state (audited 2026-05-29)

**What works:**

- `viewActor.ts` defines the protocol: commands `NAVIGATE_NEXT/PREV/TO/REPUBLISH`, events `VIEW_CHANGED/NAV_NO_PROGRESS`.
- `epubViewActor` and `pdfViewActor` both implement the protocol.
- `playerMachine.ts` invokes a `view` actor at root and `sendTo('view', ...)` for navigation.
- `EpubView` and `pdf.tsx` both wire `usePlayerMachine` with `viewLogic` + `viewInput`.
- `audioActor.ts` is the live audio side-effect actor.

**What's broken or half-done:**

1. **Dead bridge files.** `src/renderer/src/hooks/playerAudioBridge.ts` and `src/renderer/src/hooks/playerOrchestrationBridge.ts` have zero importers (verified) but still sit in the tree. The bridges contain their own `audioElement` singleton that competes with `audioActor.ts`'s singleton. Confusing for readers; risk of accidental re-import.
2. **Unresolved merge conflict.** `src/renderer/src/hooks/usePlayerMachine.ts` is in unmerged state (`UU`). The conflict is between the post-PR252 composition layer (stage 2, correct) and the pre-PR252 bridge-based version from an autostash (stage 3, stale).
3. **`usePdfSeed.ts` bypasses the view actor.** The hook reads `usePdfStore` directly, builds paragraphs in a PDF-specific shape, and sends `PARAGRAPHS_UPDATED` to the machine. EPUB has no equivalent seed hook because the EPUB view-actor protocol already covers seeding via the initial `relocated` event. PDF should do the same via `pdfViewActor`'s built-in seed-on-mount.
4. **`PARAGRAPHS_UPDATED` is a back-door.** With `usePdfSeed` gone, paragraphs would only arrive via `VIEW_CHANGED` (re-raised as `PARAGRAPHS_UPDATED` at the root). The store-subscription path in `useParagraphSubscriptions` then becomes the only legitimate external sender (e.g. for tests). This is the cleaner invariant the protocol aims for.
5. **EPUB-specific language in the machine.** `playerMachine.ts` comments mention "the EPUB rendition" and "the EPUB page arrow" around `PAGE_NAVIGATING` / `pageNavigating`. The state graph itself is format-agnostic; only the docstrings leak.
6. **PDF auto-advance bug.** When `AUDIO_ENDED` fires on the last paragraph of a PDF page, the player should `sendTo('view', NAVIGATE_NEXT)`. It doesn't (or the resulting `next()` call no-ops). The bug is suspected to involve one of: (a) `usePdfSeed` racing with the view actor's seed path; (b) `dataReady: false` snapshots arriving from `pdfViewActor` and producing premature `NAV_NO_PROGRESS`; (c) the `previousPage` reference inside `pdfViewActor` getting out of sync when the seed path bypasses the actor. The investigation is part of the work — the fix arrives after the cleanup, when the seams are gone and the failure path is easier to read.

## Target state

- Two bridge files deleted; merge conflict resolved; `audioElement` exported only from `audioActor.ts`.
- `usePdfSeed` removed; PDF and EPUB both reach the machine via the view-actor protocol. `pdfViewActor`'s existing seed-on-mount (calls `handleSnapshot(getSnapshot())` at start) becomes the single PDF seed path.
- `playerMachine.ts` docstrings reworded to be format-agnostic. `PAGE_NAVIGATING` documented as "the external navigation signal — the format's view layer started navigating before the machine asked it to" rather than as an EPUB-specific event.
- The PDF auto-advance regression has a failing test (`e2e/pdf-auto-advance-last-paragraph.spec.ts`) and a passing fix.
- All existing tests pass (`pnpm vitest`, `pnpm typecheck`).

## Out of scope

- Migrating MOBI / AZW3 to the view-actor protocol. Those formats currently seed all paragraphs at chapter-load time and don't trigger view-boundary advances during TTS, so the protocol gains them nothing today. Tracked as future work.
- Mobile parity (`apps/mobile`). The user's working-on-electron preference holds: changes here may inform `packages/shared` later but mobile is read-only for this spec.
- Restructuring the playerMachine state graph itself. 1046 lines is large, but PR #252 already shaped it; further decomposition would be a separate spec.

## Architecture invariants after this work

1. **One protocol.** Every format speaks `ViewActorCommand` / `ViewActorEmit` to the player machine. There is no format-specific event in `PlayerMachineEvent` (no `PDF_*`, no `EPUB_*`).
2. **One path for paragraphs.** Paragraphs reach the machine via `VIEW_CHANGED` (re-raised internally as `PARAGRAPHS_UPDATED`). The store-subscription `PARAGRAPHS_UPDATED` sender is preserved for tests and for legacy formats that haven't migrated, but production seeding for EPUB and PDF goes through the actor.
3. **Format readers own the actor wiring.** `EpubView.tsx` and `pdf.tsx` pass `{ viewLogic, viewInput }` to `usePlayerMachine` and own the format-specific adapter that the view actor consumes. They do not poke playerStore or playerMachine directly during normal operation.

## Acceptance criteria

- [ ] `git status` clean (no `UU` files).
- [ ] `rg "playerAudioBridge|playerOrchestrationBridge"` returns no results outside git history.
- [ ] `rg "usePdfSeed"` returns no results.
- [ ] `pnpm vitest run` passes (modulo the 2 pre-existing `better-sqlite3` failures noted in PR #252).
- [ ] `pnpm typecheck` clean.
- [ ] New e2e test `e2e/pdf-auto-advance-last-paragraph.spec.ts` passes; demonstrates that finishing the last paragraph of a PDF page advances to the next page.
- [ ] Smoke test: open a PDF, scrub to last paragraph of a page, play, verify advance to next page is automatic and lands on paragraph 0.
- [ ] Smoke test: same flow on an EPUB, ensure no regression.

## Test strategy

TDD throughout:

1. **PDF auto-advance bug:** write the failing e2e test first. If the failure mechanism is reproducible in jsdom (likely — `pdfViewActor` is unit-testable with a fake `PdfViewInput`), add a vitest unit too.
2. **Seed unification:** the existing `pdfViewActor` unit tests cover seed-on-mount. Add a test that asserts `usePdfSeed`'s removal does not break the seed (i.e. the actor's `handleSnapshot(getSnapshot())` path is what fires `PARAGRAPHS_UPDATED` for the first page).
3. **Bridge deletion:** caught by typecheck (no importers). No new test required; the existing playerMachine tests already exercise the audio + orchestration paths through `audioActor`.

## Execution order

1. Resolve the merge conflict (Task #4) — unblocks everything else.
2. Delete dead bridges (Task #5) — pure deletion, fast win, reduces diff noise for later phases.
3. Investigate PDF auto-advance (Task #7) — write the failing test, identify root cause. Root cause likely lives in the seed back-door or in `pdfViewActor`'s `dataReady` handling.
4. Unify seed path (Task #3) — likely subsumes part of the fix from #7.
5. Scrub format names (Task #1) — docstring polish, last.
6. Verification (Task #6).

## Risks

- The PDF auto-advance bug may turn out to be a `pdfViewActor` logic error unrelated to the seed path, in which case the fix is local to that file and the seed unification is independent cleanup. That's fine — both are worth doing.
- Removing `usePdfSeed` could regress the initial paragraph display if `pdfViewActor`'s seed-on-mount races with the `viewInput` resolution. The unit test for the seed path will catch this; the runtime guard (`if (!input) return () => {}`) already mitigates the race.
- The `e2e/pdf-next-paragraph-snap-back.spec.ts` test (referenced in `viewActor.ts`) should still pass after this work. Will run it as a regression check.
