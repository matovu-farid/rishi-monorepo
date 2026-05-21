# Resume Reading From Last-Played Paragraph

**Status:** Design draft
**Date:** 2026-05-21
**Scope:** `apps/rishi-electron` (renderer + main + SQLite)
**Out of scope:** mobile app parity, web sync of resume state, "clear progress" UI

## Problem

A user listens to a book via TTS, pauses or stops, then closes the app. On
reopen we already restore the *page* they were viewing (via the existing
`books.location` column), but the paragraph they were hearing is lost. They
have to scrub through the page audibly or guess where they were.

## Goal

When the reader had a paragraph actively playing or paused on close, on next
open the app must:

1. Land on the page that contains that paragraph (overriding the last-viewed
   location if they manually paged forward after pausing).
2. Visually highlight the paragraph using the same style as the active TTS
   highlight, while the reader stays paused.
3. Start playback from that paragraph when the user presses PLAY.

The feature works uniformly across EPUB, PDF, AZW3, and MOBI.

## Non-goals

- A "clear my progress" affordance. v1 only ever overwrites the field with a
  fresh paragraph; nulling it is deferred.
- A "Continue listening" home-screen pill or library cue.
- Cross-device sync of the resume paragraph.
- Sub-paragraph resume (mid-sentence). The existing `PLAY_FROM` partial-first
  flow already serves text-selection playback; resume always starts at a
  paragraph boundary.

## Persistence model

### Schema

One new column on `books`:

```sql
last_paragraph TEXT NULL
```

Stores the format-specific paragraph index string verbatim:

| Format | Example value |
|--------|---------------|
| EPUB   | `epubcfi(/6/14[chap-3]!/4/10/2,/1:0,/1:154)` |
| PDF    | `pdf-42-7` |
| AZW3 / MOBI | `1234` (numeric, stringified) |

`NULL` means "never listened yet — no resume hint."

### Migration

A single new entry in `src/main/database/migrations.ts` adds the column with
`DEFAULT NULL`. Existing rows are untouched. No backfill — every row starts
at `NULL` and the next listen populates it.

### Queries (`src/main/database/queries.ts`)

- `getBookById` (and any other path that returns a `Book` row) maps
  `last_paragraph` → `lastParagraph: string | null` on the returned object.
- New `updateBookLastParagraph(id: number, lastParagraph: string | null): void`
  performs `UPDATE books SET last_paragraph = ? WHERE id = ?`. Mirrors the
  existing `updateBookLocation` shape.

### IPC

Add a `books:updateLastParagraph` channel parallel to the existing
`books:updateLocation`:

- Main: `src/main/ipc/books/...` (match the repo's existing books-IPC layout)
  validates inputs and dispatches to the new query.
- Preload: expose on the contextBridge surface.
- Renderer API (`src/renderer/src/lib/api.ts`): export
  `updateBookLastParagraph({ bookId, lastParagraph })`.

### Test-side wiring

`src/renderer/src/test-setup.ts` adds
`updateBookLastParagraph: vi.fn().mockResolvedValue(undefined)` next to the
existing `updateBookLocation` mock so every component test gets a no-op
implementation by default.

## Read path — open-time hydration

In `routes/books.$id.lazy.tsx`:

1. `getBook` now returns `{ ...book, location, lastParagraph }`.
2. The route hands `book` (with the new field) to the format viewer.
3. The route also seeds
   `usePlayerStore.setState({ lastPlayedParagraphIndex: book.lastParagraph })`
   before the viewer mounts, so the highlight has something to key on while
   the format viewer is still warming up.

### Per-format "navigate to paragraph" resolver

Each viewer accepts `book.lastParagraph` and, **only when it resolves cleanly
to a valid in-book location**, uses it for the initial display instead of
`book.location`. Resolution failure is silent — fall back to
`book.location`.

- **EPUB** (`components/epub/EpubView.tsx`)
  `lastParagraph` is already a CFI. Pass it as the `location` prop on the
  `ReactReader` instead of `book.location`. No parsing needed.

- **PDF** (`components/pdf/PdfView.tsx`)
  New pure helper
  `pdfParagraphToPageNumber(idx: string): number | null` lives in
  `components/pdf/utils/`. Parses `pdf-{page}-{idx}` and returns the page
  number, or `null` for unrecognised inputs. On mount the viewer sets the
  initial `pageNumber` from this helper when it returns a number; otherwise
  it falls back to `book.location`.

- **AZW3 / MOBI** (`components/azw3/Azw3View.tsx`)
  `parseParagraphIndex` already exists in `components/azw3/highlight.ts` and
  yields the chapter for a given paragraph id. Build a
  `"{chapter}:0"` string compatible with `parseLocation` in
  `components/azw3/pagination.ts`, and pass that as the initial position
  instead of `book.location`.

### Resolver contract

Every per-format resolver must be **total**: malformed/unknown ids return
`null` and the viewer silently uses `book.location`. This protects against
schema drift across format versions and stale ids from earlier app builds.

## Player machine extension

Three localised deltas in `src/renderer/src/machines/playerMachine.ts`.

### 1. Extended `INITIALIZE` event

```ts
| { type: 'INITIALIZE'; bookId: string; resumeParagraphIndex?: string | null }
```

### 2. New context slot

```ts
resumeParagraphIndex: string | null   // initial = null
```

The existing `storeBookId` action becomes `storeInitParams` and writes both
`bookId` and `resumeParagraphIndex` (defaulting to `null`) from the event.

### 3. New `PARAGRAPHS_UPDATED` branch in `stopped`

```ts
PARAGRAPHS_UPDATED: [
  { guard: 'wasTimedOut',         target: 'loading',
    actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection'] },
  { guard: 'hasUnresolvedResume',                                  // NEW
    actions: ['storeParagraphs', 'applyResumeIndex'] },
  { actions: ['storeParagraphs'] }
]
```

- `hasUnresolvedResume`:
  `ctx.resumeParagraphIndex !== null
   && event.paragraphs.some(p => p.index === ctx.resumeParagraphIndex)`.
- `applyResumeIndex`: sets `paragraphIndex` to the matched array index in the
  incoming paragraphs and clears `ctx.resumeParagraphIndex` to `null` so the
  branch fires exactly once per `INITIALIZE`.

State stays `stopped`. PLAY from `stopped` already routes through `loading`
**without** zeroing the index, so playback begins from the resumed paragraph.

### Resume-id not yet on current paragraphs

The default `storeParagraphs` branch handles this. `paragraphIndex` stays at
0; `resumeParagraphIndex` stays in context. This is expected during EPUB
warm-up: paragraphs publish before the rendition finishes displaying the
target CFI. The *next* `PARAGRAPHS_UPDATED` (after the rendition lands)
matches and `applyResumeIndex` fires.

If the rendition genuinely cannot reach the paragraph (e.g., book file
modified between sessions), the user sees the page at paragraph 0 and PLAY
starts there. No timeout, no error UI. Acceptable degradation.

### Why not `paused.stale`?

`paused.stale` would automatically render the highlight via the existing
`activeParagraph` mapping, but it would also make any later
`PARAGRAPHS_UPDATED` (e.g. user manually pages forward without ever pressing
PLAY) cycle through `paused.stale → paused.stale (reenter)` — a behaviour
change unrelated to this feature. The separate `lastPlayedParagraphIndex`
store field (below) covers the highlight without touching the machine's
state graph.

## Write path — save-as-you-listen

A new subscription added in `src/renderer/src/hooks/usePlayerMachine.ts`,
alongside the existing machine wiring:

- Watch `usePlayerStore.activeParagraph`.
- When `activeParagraph` changes to a **non-null** value (transitions to
  `null` are ignored — they only mean "we're between paragraphs"):
  - Write the new id synchronously to
    `usePlayerStore.lastPlayedParagraphIndex` so the highlight stays in sync
    with live playback.
  - Schedule a 500 ms trailing-debounced `updateBookLastParagraph` IPC call
    with the new id. Rapid paragraph turnover collapses to a single write.
- On `CLEANUP` (book close / route unmount): if a debounced write is
  pending, flush it synchronously with the most-recent id so the very last
  paragraph isn't lost.
- A null `activeParagraph` is **never** persisted from this subscription.
  Nulling the field is deferred to a future "clear progress" feature.

## Highlight rendering

A new optional field on `usePlayerStore`:

```ts
lastPlayedParagraphIndex: string | null   // initial = null
```

In each format viewer the existing per-paragraph highlight check gains one
fallback: if `activeParagraph` is `null` and `lastPlayedParagraphIndex` is
equal to the paragraph's `index`, render with the active-TTS highlight
style. The instant TTS starts and sets `activeParagraph`, the
`activeParagraph` branch wins again and the highlight tracks playback
unchanged.

No new CSS. No new highlight style. Pure data-source extension on the same
visual treatment.

## Test plan (all red-first)

### Tier 1 — Pure helpers

`components/pdf/utils/pdfParagraphToPageNumber.test.ts`
- Happy: `pdf-42-7` → `42`, `pdf-1-0` → `1`.
- Malformed: `''`, `epubcfi(/...)`, `pdf-foo-7`, `pdf-`, `42` → `null`.

AZW3 path reuses existing `parseParagraphIndex` and `parseLocation` tests;
add one test that "paragraph id from chapter N" round-trips through
`parseParagraphIndex → "{N}:0" → parseLocation` to `chapter: N`.

### Tier 2 — DB layer (`queries.test.ts`)

- `updateBookLastParagraph` writes the column and returns void.
- `getBookById` returns `lastParagraph: string | null` matching what was
  written.
- Migration applies cleanly to a DB created without the column (sim-upgrade
  test).

### Tier 3 — IPC layer (`src/main/ipc/__tests__`)

- `books:updateLastParagraph` invokes the query with the right args.
- Channel rejects non-number `bookId` and non-string-or-null `paragraph`.

### Tier 4 — Player machine (`playerMachine.test.ts`)

- `INITIALIZE` with `resumeParagraphIndex` stores it in context.
- `PARAGRAPHS_UPDATED` in `stopped` with a matching id sets `paragraphIndex`
  to the matched array index and clears `resumeParagraphIndex` to `null`.
- `PARAGRAPHS_UPDATED` in `stopped` with a non-matching id leaves both
  untouched; default branch runs and stores paragraphs.
- After resume is applied, `PLAY` enters `loading` with the correct
  `paragraphIndex`.
- A second `PARAGRAPHS_UPDATED` after resume has already been applied falls
  into the default branch (no re-fire).
- `wasTimedOut` branch still takes priority over `hasUnresolvedResume`.

### Tier 5 — Player hook write path (`usePlayerMachine` focused test)

- `activeParagraph` change → `lastPlayedParagraphIndex` mirrors immediately.
- Debounced IPC write fires exactly once after 500 ms of quiet across rapid
  paragraph changes.
- `CLEANUP` flushes a pending debounced write synchronously.
- A null `activeParagraph` does not trigger any write.

### Tier 6 — Per-format viewer smoke tests

For each of EPUB / PDF / AZW3:
- When `book.lastParagraph` is set and resolves, initial display uses it
  (not `book.location`).
- When `book.lastParagraph` is `null`, initial display falls back to
  `book.location`.
- When `activeParagraph` is `null` and `lastPlayedParagraphIndex` matches a
  visible paragraph, that paragraph renders with the active-TTS highlight
  style.

### Tier 7 — E2E (one Playwright spec under `e2e/`)

Open a book → let TTS play through 2 paragraphs → pause → close window →
reopen → assert: the third paragraph is highlighted, reader is paused, PLAY
resumes from there.

## Build sequence (TDD, agent-team)

Each tier is red → green → refactor before the next begins.

1. **researcher** verifies: (a) the CFI stored from epubjs `relocated`
   events is the same form accepted by `rendition.display(cfi)`; (b)
   `parseParagraphIndex` is total over current AZW3/MOBI paragraph ids in
   the production-shaped fixtures.
2. **planner** locks the build order: DB+IPC → machine → write path →
   per-format hydration → highlight → E2E.
3. **architect** signs off on the two non-obvious boundaries:
   - `lastPlayedParagraphIndex` placement on `usePlayerStore` (vs. a new
     store).
   - The `hasUnresolvedResume` guard contract (id-string equality, not
     array-index equality).
4. **tester** writes red phase for tiers 1–5.
5. **coder** runs green → refactor against the locked tests.
6. **reviewer** runs at the end against the diff with ≥80% confidence
   filter.

## Files

### New

- `src/main/ipc/books/updateLastParagraph.ts` (or extension to the existing
  books IPC module — match repo convention)
- `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.ts`
- `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.test.ts`
- One E2E spec under `e2e/`
- This design doc

### Modified

- `src/main/database/schema.ts`
- `src/main/database/migrations.ts`
- `src/main/database/queries.ts`, `queries.test.ts`
- `src/preload/*` (contextBridge exposure)
- `src/renderer/src/lib/api.ts`
- `src/renderer/src/test-setup.ts`
- `src/renderer/src/machines/playerMachine.ts`, `playerMachine.test.ts`
- `src/renderer/src/hooks/usePlayerMachine.ts` (+ focused test)
- `src/renderer/src/stores/playerStore.ts`
- `src/renderer/src/routes/books.$id.lazy.tsx`
- `src/renderer/src/components/epub/EpubView.tsx`
- `src/renderer/src/components/pdf/PdfView.tsx`
- `src/renderer/src/components/azw3/Azw3View.tsx`
- `src/renderer/src/components/mobi/MobiView.tsx`

## Risks and mitigations

- **CFI drift between sessions** — an EPUB CFI saved one session can fail to
  display in the next if the rendition's pagination differs. Mitigation:
  resolver failure falls back to `book.location`, which is already
  drift-tested by the existing location-restore code path.
- **PDF paragraph id format change** — `pdfParagraphToPageNumber` is a
  single pure function; format changes get caught by its unit tests before
  shipping.
- **Debounced write swallowed by crash** — a renderer hard crash between
  the in-memory mirror and the 500 ms flush loses up to one paragraph of
  progress. Acceptable: same envelope as the existing `book.location`
  write, which is also async-debounced.
- **Two writes racing (resume save + cleanup flush)** — the cleanup path
  must flush *before* the route's `useEffect` reset runs `cleanupAudio`;
  effect ordering in `usePlayerMachine.ts` keeps the flush inside the same
  teardown closure that owns the debounce timer, so no race.
