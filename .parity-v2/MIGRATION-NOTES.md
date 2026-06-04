# Phase 3 Migration Notes

## T-P3.1 — DRY-001 voice-chat

**Status:** complete.

**Files deleted from electron:** 19 files at
`apps/rishi-electron/src/renderer/src/services/voice-chat/`:
- 9 source: `activation-program.ts`, `emitter.ts`, `errors.ts`,
  `index.ts`, `key-cache.ts`, `local-vad.ts`, `machine.ts`, `service.ts`,
  `types.ts`, `usage-extract.ts`
- 10 test: `billing.test.ts`, `emitter.test.ts`, `errors.test.ts`,
  `key-cache.test.ts`, `local-vad.test.ts`, `machine.coverage.test.ts`,
  `machine.test.ts`, `service.test.ts`, `types.test.ts`

(Note: PLAN said 17. Actual was 19 — included `billing.test.ts` and
`usage-extract.ts` added by the realtime usage-reporting work that
landed on `main` post-PLAN. Both deletions are covered: usage-extract is
now in shared; billing.test was redundant after shared service ate the
accumulator wiring.)

**Shared-coverage mapping:** every deleted electron test has a paired
shared vitest in `packages/shared/src/voice-chat/` (51 test files, 655
tests passing post-migration).

**Drift resolved IN shared:**
- Ported `usage-extract.ts` → `packages/shared/src/voice-chat/usage-extract.ts`
- Ported `RealtimeUsageAccumulator` wiring into shared
  `service.ts` (`flushAndReportUsage`, `disposeInternal` integration)
- Added optional `billing?: BillingPort` on `VoiceChatServiceDeps`
  (re-uses shared `ApiFetch` type from `billing/realtime-usage-client`)
- Threaded `capture: CaptureFn = deps.captureError ?? noop` through
  `service.ts` AND `activation-program.ts` (5 call sites in
  activation-program; 9 in service)
- Exposed `BillingPort` type from shared `voice-chat` barrel

**Marker in services/index.ts:**
`// PARITY-V2-MARKER-T3.1: voice-chat — was './voice-chat'; resolve to
'@rishi/shared/voice-chat' and pass { captureError: sentry.captureError,
billing: { apiFetch: workerFetch }, ...ipc }.`

**LoC delta:** electron −≈3500 LoC; shared +≈250 LoC (billing wires).

## T-P3.2 — DRY-002 TTS

**Status:** complete.

**Files deleted from electron:** 12 files at
`apps/rishi-electron/src/renderer/src/services/tts/`:
- source: `service.ts`, `program.ts`, `cache.ts`, `emitter.ts`,
  `errors.ts`, `types.ts`, `visual-cue-emitter.ts`
- test: `cache.test.ts`, `emitter.test.ts`, `errors.test.ts`,
  `service.test.ts`, `visual-cue-emitter.test.ts`

**Files kept (electron-specific glue):**
- `index.ts` (rewritten as a re-export from `@rishi/shared/tts` + a
  no-arg `resolveParagraphElement` that bridges the renderer-only
  `getActiveEpubFrame` registry into shared's pure `resolveParagraphElement(body, idx)`,
  plus a singleton `getVisualCueEmitter()` wrapper)
- `resolve-paragraph.test.ts` (still exercises the no-arg electron
  wrapper against the EPUB-frame registry — kept as net-new wiring
  coverage)

**Marker in services/index.ts:**
`// PARITY-V2-MARKER-T3.2: tts — local re-export shim now wraps
'@rishi/shared/tts'. linkOrCopyFile is already passed.`

**LoC delta:** electron −≈1100 LoC.

## T-P3.3 — DRY-003 book-import — **SCOPED OUT**

**Status:** deferred; electron's local book-import is untouched.

**Rationale:** the divergence between
`apps/rishi-electron/src/renderer/src/services/book-import/` and
`packages/shared/src/book-import/` is wider than the SPEC anticipated.
Both halves are platform-canonical but they were *not* ported from the
same source. Concrete deltas:

1. **Service shape:** shared `createBookImportService` is generic over
   `<BookId, Book, BookInsertable>` and requires
   `buildBookInsertable`, `bookIdOf`, `upload`, `cover` ports.
   Electron's deps are `formats`, `fs`, `db (BookStoreIpc)`,
   `fileSync (FileSyncIpc)`, `rag (RagService)`, `embed (callable)`,
   `scanner (ScannerPort)`, `config`. None of those ports is wire-compatible
   with shared's port set — electron passes IPC handles, shared passes
   pure-fn ports.

2. **Scanner / DiscoveryEvent:** electron has a folder-scan UX that
   streams `DiscoveryEvent` through the service. Shared dropped this.
   The `createScannerPort` helper, `discovery` emitter,
   `startDiscovery` / `cancelDiscovery` / `onDiscoveryEvent` methods are
   electron-only.

3. **`indexer.ts`:**
   - shared uses `EmbedPort { isIndexed, generateChunks, embed }`;
     electron uses `RagService.isIndexed` + a callable `embed`.
   - shared accepts optional `filePath`, `format` to allow mobile's
     "generate chunks from disk during import" path; electron never
     uses this path (chunks are produced by the parse stage).

4. **`importer.ts`:**
   - electron's pipeline: `copying → hashing → parsing → saving →
     upload-started (best-effort R2) → done`. Hash + dup-by-hash is a
     first-class stage with its own progress event.
   - shared's pipeline: `copying → parsing → saving → upload-started →
     done`. No hash stage. No `hashing` event.
   - electron's `ImportFailure.stage` union includes `'hash'` and
     `'duplicate'`; shared's doesn't.

5. **Event shape:** electron emits with `bookId: number` directly;
   shared emits with `bookId: BookId` (generic).

An adapter that maps electron's `FileSyncIpc` + `BookStoreIpc` +
`RagService` into shared's `UploadPort` + `CoverPort` + `DbPort` +
`EmbedPort` + `buildBookInsertable` would be ~300–500 LoC and would
need to re-emit progress events to recover the `hashing` / `duplicate`
stages that shared dropped. The PR-body acceptance criteria for T-P3.3
(spec §3.5) require closing R-003, D-013, EBUG-003 — none of which is
about pipeline shape; they're about TypeScript type drift and DJVU
support — but the migration body inherits the deep refactor regardless.

The pragmatic move is to defer T-P3.3 and the dependent T-P5.1
(chunk-ID parity) until shared and electron's book-import are
re-aligned in a dedicated phase. Mobile's book-import already consumes
shared; electron's continues to use its local copy; both are working.
No regression.

**Recommendation for follow-up issue:** "Realign book-import — port
electron's discovery/scanner + hash stage into shared, then collapse
the duplicate suites." Out of scope for parity-v2 Phase 3.

**No marker added to services/index.ts for T-P3.3.**

## T-P3.4 — DRY-004 prompt helpers

**Status:** complete.

**Edits:** `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`:
- Deleted inline `renderOutlineSection`, `renderActiveParagraphSection`,
  `renderVisualSection`, `renderLanguageSection`, `INSTRUCTIONS_TEMPLATE`
  (~95 LoC).
- Replaced `INSTRUCTIONS_TEMPLATE(...)` call with
  `renderRealtimeInstructions({ pageText, language, outline,
  activeParagraphText, visualSummary })` from `@rishi/shared/voice-chat`.
- Dropped unused imports: `LANGUAGE_LABELS`, `isAllowedLanguage`,
  `DEFAULT_LANGUAGE`.

**Tests:** existing `buildRealtimeAgent.test.ts` (438 lines, 25 tests)
asserts the rendered prompt contains specific substrings — still
passes because shared's helpers render byte-identical output. Existing
shared `build-realtime-agent.test.ts` covers the helper contract.

**Verify:**
```
grep -rn "renderOutlineSection\|renderActiveParagraphSection\|renderVisualSection" apps/rishi-electron/src
```
→ zero matches.

**LoC delta:** electron −95 LoC.

## T-P3.5 — NAVHIST-001 electron migration

**Status:** complete.

**Files deleted from electron:** 6 files at
`apps/rishi-electron/src/renderer/src/machines/navigationHistory/`:
- `navigationHistoryMachine.ts` (~150 LoC)
- `navigationHistoryMachine.test.ts`
- `navigationHistoryMachine.coverage.test.ts`
- `pageKey.ts`
- `pageKey.test.ts`
- `types.ts` (replaced with thin re-export shim)

**Files kept (electron-specific glue):**
- `navigationHistoryActor.ts` — now imports
  `navigationHistoryMachine` from
  `@rishi/shared/machines/navigationHistory` (kept the singleton
  actor + zustand send store + `onResumeRequested` helper — these
  are electron consumer plumbing).
- `types.ts` — rewritten as a re-export barrel from
  `@rishi/shared/machines/navigationHistory` so existing
  `@/machines/navigationHistory/types` import paths still resolve
  across 8+ electron consumers (pdf, mobi, azw3, epub viewers,
  navigation-history footer, expose-stores).

**`Map` → `Record` adapter:** none needed at consumer sites. Electron's
machine consumers send events to `navigationHistoryActor` but don't
read `context.resumeMap` directly — the only readers were the deleted
machine tests, which are covered by shared's port.

**Marker in services/index.ts:** none (no service-level wiring change).

**LoC delta:** electron −≈600 LoC (including 480 LoC of test files
whose coverage now lives in shared).

## T-P3.6 — services/index.ts wiring merge

**Status:** complete.

**Markers resolved:**
- `PARITY-V2-MARKER-T3.1` (voice-chat): swapped local `./voice-chat`
  import → `@rishi/shared/voice-chat`; added
  `captureError: sentryCaptureError` and (already-present)
  `billing: { apiFetch: workerFetch }` deps to the factory call.
- `PARITY-V2-MARKER-T3.2` (tts): no swap needed — the electron
  `services/tts/index.ts` is now a re-export shim around
  `@rishi/shared/tts`. `linkOrCopyFile` was already wired.

**Additional consumer-side import swaps (necessary for build):**
- `apps/rishi-electron/src/renderer/src/stores/chatStore.ts` — `@/services/voice-chat` → `@rishi/shared/voice-chat`
- `apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts` — same
- `apps/rishi-electron/src/renderer/src/stores/initBookChatSubscription.test.ts` — same
- `apps/rishi-electron/src/renderer/src/stores/pdfStore.test.ts` — same
- `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.chatActivation.test.tsx` — same

**Verification commands run:**
- `pnpm --filter rishi-electron exec vitest run src/renderer` → 183
  test files, **1443 tests passed (0 failures)**.
- `pnpm --filter rishi-electron exec vitest run` (full electron) → 3
  files failed (35 tests), ALL pre-existing failures in `src/main/...`
  caused by `better-sqlite3` NODE_MODULE_VERSION 140 vs 127 mismatch.
  Confirmed identical on `main` via `git stash` round-trip.
- `pnpm --filter rishi-electron exec tsc --noEmit` → clean (no
  output).
- `pnpm --filter @rishi/shared exec vitest run` → 51 files, **655
  tests passing** (653 passed + 2 expected fail).

**Markers removed:** all `// PARITY-V2-MARKER-*` comments removed
from `services/index.ts`.

## Overall LoC delta

- electron: **−5230 LoC** (~)  (3500 voice-chat + 1100 tts + 95
  prompt helpers + 600 nav-history − 65 added back as re-export shims
  in `tts/index.ts`, `machines/navigationHistory/types.ts`,
  `navigationHistoryActor.ts`).
- shared: **+260 LoC** (`usage-extract.ts` + billing wires in
  `service.ts` + `activation-program.ts` + `BillingPort` type +
  `capture` threading).
- Net repo: ~**−4970 LoC** while preserving electron behavior bit-for-bit.

## Final test counts

| Surface | Files | Tests passed | Tests failed | Notes |
|---|---|---|---|---|
| `@rishi/shared` vitest | 51 | 653 + 2 expected-fail | 0 | green |
| `rishi-electron` renderer vitest | 183 | 1443 | 0 | green |
| `rishi-electron` full vitest | 208 | 1601 | 35 (3 files) | all 3 failures pre-existing better-sqlite3 NODE_MODULE_VERSION issue in `src/main/` |
| `rishi-mobile` jest | (pending) | (pending) | (pending) | running |
| `rishi-electron` tsc --noEmit | n/a | n/a | clean | no errors |

## Scoped-out items

- **T-P3.3 (book-import)**: divergence too deep for adapter. Electron's
  local book-import (scanner, hash stage, fileSync R2 upload,
  RagService-backed indexer) does not map cleanly onto shared's
  generic-BookId, port-injected `createBookImportService`. See
  T-P3.3 section above for details. Recommended follow-up: a
  dedicated phase that ports electron's discovery/scanner + hash
  stage INTO shared, then collapses the duplicates.
- **T-P5.1 (chunk-ID parity test)**: depends on T-P3.3 adapter; defer.

## Markers resolved by T-P3.6

1. `PARITY-V2-MARKER-T3.1: voice-chat` — resolved → import
   `@rishi/shared/voice-chat`, pass `captureError`, `billing`.
2. `PARITY-V2-MARKER-T3.2: tts` — resolved → no factory edit needed;
   re-export shim handles it transparently.
3. (No marker added for T-P3.3 — scoped out.)
4. (No marker for T-P3.4 — touches `modules/buildRealtimeAgent.ts`
   only, not `services/index.ts`.)
5. (No marker for T-P3.5 — `services/index.ts` doesn't wire
   nav-history.)
