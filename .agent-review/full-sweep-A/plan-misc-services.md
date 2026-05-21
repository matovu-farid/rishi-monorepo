# Phase A — Planner 4: Connectivity + Indexing + Reader-Cache

**Scope:** 6 test files across three service clusters under
`apps/rishi-electron/src/renderer/src/services/`. Pilot lesson: the warm-restore
logic that the unit-store tests do NOT cover lives in `reader-cache/`. That
makes `cache.test.ts` (and the un-tested `pdf-cache.ts` / `epub-cache.ts`)
this planner's primary finding surface.

**Tester ID range (assignable to this plan's wildcard tester slot):**
A091-A100 for reader-cache + cross-cutting. A071-A080 connectivity,
A081-A090 indexing.

---

## 1. Skip list (PILOT LESSON 1)

Read every assigned file with `grep -n "\\.skip\\|\\.only\\|todo("`.
Findings expected: **none skipped**. All six files run unconditionally
and report passing today. Verified by inspection:

- `service.test.ts` — 7 `it(...)`, no `.skip`.
- `subscribers.test.ts` — 3 `it(...)`, no `.skip`.
- `types.test.ts` — 5 `it(...)`, all `expectTypeOf` (compile-time only).
- `index-program.test.ts` — 14 `it(...)`, no `.skip`. Uses real `Effect.runPromise`.
- `text-extraction.test.ts` — 4 `it(...)`, real PDF fixture, no `.skip`.
- `cache.test.ts` — 10 `it(...)`, no `.skip`.

If a tester runs the suite and a test reports `skipped`, that's news —
file in `parity-gaps.md`, not in `findings/`.

---

## 2. Reader-cache coverage matrix (SPECIAL FOCUS)

The pilot called `cache.ts` (the LRU) "solid" but flagged that
`pdf-cache.ts` and `epub-cache.ts` could have gaps. Build a matrix of
**every public export** versus what `cache.test.ts` actually exercises.

### 2.1 `cache.ts` — public `ReaderCache<T>` surface

| Method | Tested? | Notes |
|---|---|---|
| `get(id)` returns entry on hit | YES | "round-trips a stored entry" |
| `get(id)` returns undefined on miss | YES | "returns undefined on miss" |
| `get(id)` updates `lastAccess` | YES | "refreshes lastAccess on get" |
| `get(id)` increments `stats.hits` | NO | **gap** — stats counter never asserted |
| `get(id)` increments `stats.misses` | NO | **gap** — stats counter never asserted |
| `set(id, doc, bytes)` insert path | YES | round-trip test |
| `set(...)` LRU evict by count | YES | "evicts the least-recently-used entry" |
| `set(...)` LRU evict by byte budget | YES | "evicts older entries to stay under maxTotalBytes" |
| `set(...)` replace-in-place (same id, different doc) | YES | "destroys the old document when replacing" |
| `set(...)` no-op on identical doc (same id, same doc ref) | YES | "no-ops when re-setting the exact same document" |
| `set(...)` over `maxEntryBytes` refuses + drops stale | YES | both per-entry-cap tests |
| `set(...)` budget composition (count + bytes) | YES | "count cap and byte cap compose" |
| `set(...)` async/Promise destroy (`void opts.destroy(...)`) | NO | **gap** — destroy returning a Promise that REJECTS is unhandled; nothing asserts cache stays consistent |
| `set(...)` concurrent calls under the same id | NO | **gap** — concurrent set never tested; Map writes are sync but could interleave under await-boundary |
| `evict(id)` destroys + removes | YES | "evict destroys the cached document" |
| `evict(id)` no-op on unknown | YES | "evict is a no-op for unknown ids" |
| `has(id)` | NO | **gap** — diagnostic only, but it IS the e2e contract (used by `window.__readerCache.<fmt>.has(id)` per `epub-warm-restore.spec.ts`). One direct assertion would close the contract. |
| `size()` | NO | **gap** — same as `has`; e2e-contract surface untested at unit level |
| `stats()` returns `{hits, misses}` | NO | **gap** — exists but never asserted |
| `resetStats()` zeroes counters | NO | **gap** — e2e tests rely on this between cold/warm runs |

**Behavioral edges not exercised by `cache.test.ts`:**

- The `maxTotalBytes > 1` guard in `set()` at L136 (`entries().size > 1`).
  Edge case: a single inserted entry larger than `maxTotalBytes` but
  smaller than `maxEntryBytes` — should it survive? The current code
  says yes (the `> 1` guard short-circuits eviction). One test confirms
  the "single entry at the cap" case, but not "single entry over the
  total cap, under per-entry cap." That's a real config (the production
  defaults satisfy `maxEntryBytes <= maxTotalBytes`, but the contract
  doesn't enforce it).
- `evictOldest()` tie-breaking when two entries share `lastAccess` (likely
  on fast hardware without the busy-wait). The current code picks
  whichever Map iteration returns first. Not tested.
- LRU correctness after `evict()` then `set()` under the same id (does
  lastAccess reset correctly? Yes by code; not asserted).

### 2.2 `pdf-cache.ts` — public surface

| Export | Tested? | Notes |
|---|---|---|
| `getCachedPdf(bookId)` | NO | **gap** — only `cache.ts` (the factory) tested; the `pdf` instance is not |
| `setCachedPdf(bookId, proxy, bytes)` | NO | **gap** |
| `evictPdf(bookId)` | NO | **gap** |
| `pdfCache` config (maxEntries=3, maxEntryBytes=50MB, maxTotalBytes=150MB) | NO | **gap** — a regression that, say, sets `maxEntries=1` would silently ship |
| `window.__readerCache.pdf` diagnostic surface mounted | NO | **gap** — e2e tests rely on this; if the `typeof window` guard misfires or `__readerCache` is overwritten, e2e silently breaks at runtime |
| Diagnostic re-init when both `pdf-cache.ts` and `epub-cache.ts` load (does `w.__readerCache.epub` overwrite `pdf`?) | NO | **gap** — both files use the `w.__readerCache = w.__readerCache ?? {}` pattern; correct, but worth a unit assertion that both keys coexist after both module loads |
| `destroy: (proxy) => proxy.destroy()` returns a Promise (PDFDocumentProxy.destroy is async) | NO | **gap** — combined with the `void opts.destroy(...)` issue above, a rejected destroy is swallowed |

### 2.3 `epub-cache.ts` — public surface

Same shape as pdf-cache; same gaps:

| Export | Tested? | Notes |
|---|---|---|
| `getCachedEpub`, `setCachedEpub`, `evictEpub` | NO | **gap** |
| `epubCache` config | NO | **gap** |
| `window.__readerCache.epub` mount | NO | **gap** — actively consumed by `epub-warm-restore.spec.ts` (currently skipped) |

**Tester recommendation:** the strongest, most concrete findings from
this slice will be (a) stats counters never asserted, (b) the entire
`pdf-cache.ts` / `epub-cache.ts` modules being untested at unit level,
and (c) the e2e diagnostic surface contract being implicit.

Note: most of these are **practices/parity gaps**, not production bugs.
A finding requires a concrete production-behavior breakage. The only
candidate behavior bug I see by inspection is the swallowed
`destroy()` Promise rejection — but that's design-by-discard and may be
intentional. Flag it in `parity-gaps.md` for discussion, not in `findings/`,
unless the tester can produce a failing assertion.

---

## 3. Per-file audit checklist

### 3.1 Connectivity (3 files)

**`service.test.ts`** — uses `makeFakeSource` (a pure in-memory fake of
`window`/`navigator`'s event API). This is the *right* call — `happy-dom`
gives you a `window` but its `online`/`offline` event semantics differ from
real navigator behavior across browsers; an inline fake is more reliable
and faster.

- ✅ Don't flag the fake as "mocking the network." This is a unit boundary
  around the `ConnectivitySource` port; `service.ts` literally takes a
  `source: ConnectivitySource` dep. A real fetch+timeout would test the
  network library, not the service.
- Gaps worth checking (file as practice/parity, not findings unless they
  expose a real bug):
  - **Start-time reconciliation path** (service.ts L46-49) — the machine's
    initial state may drift from `source.onLine` at start(); production has
    code to send a corrective `ONLINE`/`OFFLINE`. No test exercises a source
    whose `onLine` differs from whatever the xstate machine's initial state
    is. If the machine's initial state is hard-wired to `online` and you
    start with an offline source, do subscribers get notified? Inspect.
  - **`stop()` preserves `lastOnline` for isOnline()** (L80) — tested that
    listeners don't fire after stop, but NOT tested that `isOnline()`
    continues to return the last-known value after stop.
  - **`subscribe()` before `start()`** — undocumented; what happens?
  - **Subscriber thrown errors** — does one throwing listener prevent
    others from being notified? Look at `subscribers.notify()` impl
    (subscribers.ts is 30 LOC; check whether it try/catches per listener).
  - **`isOnline()` after stop+start cycle** — actor reference is replaced;
    does the new actor reconcile state correctly?

**`subscribers.test.ts`** — 3 tests cover add/notify/remove. Gaps:

- No test for adding the same listener twice (Set vs Array behavior).
- No test for remove() of an unknown listener.
- No test for notify() while a subscriber mutates the set (add/remove
  during iteration — common bug source).
- No test for the listener throwing — does notify abort or continue?
  This is a real production concern; the service composes this with
  user-supplied callbacks via `service.subscribe()`.

**`types.test.ts`** — `expectTypeOf` compile-time checks. The file
already asserts the cross-package contract (`ConnectivityService` →
`ConnectivityPort` from `@/services/sync/types`). Solid as-is; do not
file unit-test findings — types tests are useful precisely *because*
they're small.

- One gap: no `expectTypeOf` assertion that the unsubscribe fn (return
  value of `subscribe`) returns `void`. The runtime test covers this
  but the type doesn't.

### 3.2 Indexing (2 files)

**`index-program.test.ts`** — exercises the real Effect program. No
embedding model mocked; `extract`/`saveChunks`/`processJob` are the
ports, mocked as plain async functions. **This is correct** — the
indexer's responsibility is scheduling + ID derivation; the embedding
model lives behind `processJob`. Mocking that port matches production
(production passes a real worker handle through `processJob`).

Verify the mock contract matches production:

- Production `processJob` signature: `(pageNumber: number, items: ProcessJobItem[]) => Promise<void>` —
  matches deps interface (index-program.ts L20). ✅
- Production `saveChunks` signature: `(chunks: IndexChunk[]) => Promise<void>` —
  matches. ✅
- Production `extract` returns `string[]` (paragraphs); the test
  always returns `[\`page \${n}\`]` style. Real production is
  `extractPageParagraphs` which can return `[]`. The "skips pages
  with no paragraphs" test covers the empty case. ✅
- Test does NOT assert backpressure when `saveChunks` is slow (e.g.,
  DB latency); the concurrency bound is over `extract`, not over
  `saveChunks`. Confirm by inspection whether that matters for
  production behavior. **Possible gap.**

Other gaps to check:

- The `pagesAroundCenter` function has a `Math.trunc(centerRaw) || 1`
  branch — `startPage: 0` would trip this. Not tested.
- No test for `numPages: 0` (vacuous case — should onFinish still fire?).
- No test for the interaction of `skipPages` with `startPage` when
  `startPage` itself is the only schedulable page that's skipped *and*
  numPages=1 — does onFinish still fire? (The "skipPages of every page"
  test gets close but uses numPages=3.)
- `onError` is called with `err.message` — never with the original
  Error object. Tests confirm this. Is that intentional? It loses
  the stack. Flag in practices if egregious.

**`text-extraction.test.ts`** — uses the **real PDF fixture**
(`e2e/fixtures/test-book.pdf`) and the **real pdfjs-dist** in the
legacy/no-worker mode. This is exemplary; do not flag the lack of mocks.

Gaps:

- `loadPdfDocument` has an Electron-vs-Node branch (L10-15) that's only
  exercised in Node mode by these tests; the Electron branch is never
  unit-tested. Fine — it's covered in e2e.
- No test for malformed-PDF bytes (rejection path). `pdfjs.getDocument`
  rejects on bad input — what should `loadPdfDocument` do? Currently
  propagates. Confirm.
- No test that `extractPageParagraphs` rejects on `pageNumber < 1`
  (the guard returns `[]`, which is tested; the upper-bound version
  is tested too — symmetric is fine).
- `page.cleanup()` runs in `finally`, but if `getTextContent()` throws,
  the page is cleaned up but the error is rethrown. No test for that path.
- **Behavior-over-implementation risk:** `expect(paragraphs.length).toBeGreaterThanOrEqual(4)`
  is reasonable (the test acknowledges the algorithm's responsibility),
  but if the upstream `pageDataToParagraphs` algorithm changes, this
  test fails for the right reason. Defend, don't flag.

### 3.3 Reader-cache (1 file)

**`cache.test.ts`** — covered exhaustively in §2 above.

Concrete anti-patterns to look for at the test level:

- **LRU ties:** the tests use `await sleep(2)` between `set()` calls to
  force `lastAccess` separation. On slow CI this is fine; on a future
  high-res-clock environment it should still hold (`Date.now()` ms
  resolution + 2ms sleep ≥ 1ms delta). Acceptable. If a tester wants
  to make it deterministic, suggest injecting a `now: () => number`
  port — but that's a design change, not a fix-this-run item. → Type B
  test-quality.
- **Concurrent set under the same id:** not tested. `set()` is sync
  inside the closure but `destroy()` is `void opts.destroy(...)` — fire
  and forget. If a tester reproduces a state where a stale destroy
  Promise rejects after the new entry is in place, that's a real
  finding. Hard to reproduce; flag as backlog if pursued.
- **Oversized entry handling:** tests cover refuse-and-drop-stale. Edge
  case: oversize entry sets the *same doc ref* under the same id. Code
  at L107-109 checks `stale.document !== document` before destroying;
  same-ref means stale stays *destroyed-list-clean* but the entry is
  still deleted from the Map (L111). Probably correct, but the
  asymmetric handling vs. the in-place no-op path (L121, "no-ops when
  re-setting the exact same document") is worth one assertion.

---

## 4. TDD guidance

Repo convention: Vitest with `globals: true`, environment is
`happy-dom`, test setup `src/renderer/src/test-setup.ts`. Mocks are
inline; `vi.mock(...)` is rare in this slice and should stay that way.

**Patterns to keep using:**

- `it('should <behavior>', () => {})` — `it` not `test`.
- `beforeEach` to reset shared state (`cache.test.ts` does this).
- Real `Effect.runPromise` / `Effect.runFork` for `index-program`.
- Real PDF fixture for `text-extraction` (`e2e/fixtures/test-book.pdf`).
- Inline fakes for ports (`makeFakeSource` in `service.test.ts`).
- `expectTypeOf` for type contracts (`types.test.ts`).

**Patterns to add ONLY if a finding requires:**

- `vi.useFakeTimers()` — only if a test needs deterministic
  `Date.now()` for LRU tie-break testing. Don't introduce gratuitously.
- `vi.mock('pdfjs-dist')` — DO NOT. `text-extraction.test.ts` works
  with the real lib.

**Red-test placement for findings:**

| Bug class | File |
|---|---|
| LRU/byte-budget regression in `cache.ts` | `cache.test.ts` |
| `pdf-cache.ts` / `epub-cache.ts` module-init regression | new `pdf-cache.test.ts` / `epub-cache.test.ts` (small, ~20 LOC each) |
| Diagnostic surface (`window.__readerCache.<fmt>`) broken | new `pdf-cache.test.ts` — asserts the global exists after import |
| Connectivity reconcile/teardown drift | `service.test.ts` |
| Subscriber error isolation | `subscribers.test.ts` |
| `index-program` scheduling edge | `index-program.test.ts` |
| pdfjs malformed input | `text-extraction.test.ts` |

---

## 5. Finding-file rules

Template: `/Users/faridmatovu/projects/rishi-monorepo/.agent-review/FINDING-TEMPLATE.md`.
Save to `.agent-review/full-sweep-A/findings/AXXX-<slug>.md`.

**ID range allocation for this plan's surface:**

- **A071-A080 → connectivity** (3 test files). Max 5 findings/file but
  realistically expect 1-3 total across the cluster; the tests are
  small and tight.
- **A081-A090 → indexing** (2 test files). Expect 1-3 total — the
  index-program tests are unusually thorough already.
- **A091-A100 → reader-cache + wildcard cross-cutting**. This is the
  highest-yield surface per the pilot. Expect 2-5. Reserve A099-A100
  for cross-cutting findings the tester notices that span clusters.

**Reviewer alternation:** finding ID's last digit decides reviewer.
Odd → `team-reviewer`; even → `feature-dev:code-reviewer`. Set
`reviewer1_agent_type` in YAML frontmatter accordingly.

**What's NOT a finding (route elsewhere):**

- "Stats counters not asserted" → `practices-audit.md` (Type B).
- "`pdf-cache.ts` / `epub-cache.ts` have no unit test" → `parity-gaps.md`.
- "LRU tie-break is non-deterministic" → `test-infra-backlog.md`
  (needs an injectable clock; design change).
- "subscriber throw isolation" — IF you can demonstrate production
  callers (sync, etc.) get silently dropped, this IS a finding. IF
  you can't, it's a practice gap.

Per-finding dispatch cap: 8 (unchanged). Total findings cap for this
plan's surface: 5 per file (workflow rule), realistically 5-10 total.

---

## 6. Test commands

Repo root: `/Users/faridmatovu/projects/rishi-monorepo`. All vitest runs
use the `--filter rishi-electron` workspace selector.

Per-file:

```bash
pnpm --filter rishi-electron test src/renderer/src/services/connectivity/service.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/connectivity/subscribers.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/connectivity/types.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/indexing/index-program.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/indexing/text-extraction.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/reader-cache/cache.test.ts
```

Cluster runs:

```bash
pnpm --filter rishi-electron test src/renderer/src/services/connectivity/
pnpm --filter rishi-electron test src/renderer/src/services/indexing/
pnpm --filter rishi-electron test src/renderer/src/services/reader-cache/
```

Single `it`: `-t "<partial name>"`. Example:

```bash
pnpm --filter rishi-electron test src/renderer/src/services/reader-cache/cache.test.ts -t "LRU"
```

Reviewer-1 flake check (run failing test ≥3×):

```bash
for i in 1 2 3; do \
  pnpm --filter rishi-electron test <path> -t "<name>" || echo "run $i: FAIL"; \
done
```

No Playwright run is needed for any file in this plan; build is **not**
required.

`text-extraction.test.ts` reads from `e2e/fixtures/test-book.pdf`.
Confirm the fixture exists before assuming an "extraction returns
empty" finding is a production bug:

```bash
test -f /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/e2e/fixtures/test-book.pdf && echo OK
```

---

## 7. Project-config check (PILOT LESSON 2)

Before claiming a per-file config tweak has impact, the wave-8 triager
(and any tester citing config behavior) must check the project-level
config:

- **Vitest config:** `apps/rishi-electron/vitest.config.ts` (and the
  shared root if any). Globals, environment (`happy-dom`), setup file,
  test timeout, reporters.
- **TS config for tests:** `apps/rishi-electron/tsconfig.web.json` (or
  the test-specific one). Path aliases — `@/services/...` is used
  in `types.test.ts`.
- **`text-extraction.test.ts` path math** is via
  `fileURLToPath`/`resolve(__dirname, '../../../../../e2e/fixtures/...')`.
  If a future restructure moves the file, this breaks silently (file-not-
  found → `readFileSync` throws at `beforeAll`). Not a config issue per
  se, but the same class of "remote source of truth" — flag if relevant.
- `index-program.test.ts` uses real `Effect.runPromise`; no fake timers
  globally configured (verify `vitest.config.ts` does NOT set
  `fakeTimers.toFake`). The `setTimeout`-based sleeps in tests depend
  on real timers.
- `cache.test.ts` `Date.now()` + 2ms sleep deltas — same dependency on
  real timers. If vitest were globally configured for fake timers,
  every LRU test would deadlock.
- Per-file `testTimeout` is not set in any of these six files; the
  project default applies. Removing per-file overrides where none
  exist is a no-op — don't propose it.

**Pre-publication checklist for any test-quality fix in this surface:**

1. Read `apps/rishi-electron/vitest.config.ts`.
2. Read `apps/rishi-electron/tsconfig.web.json`.
3. Confirm proposed change is not already covered globally.
4. Confirm proposed change doesn't conflict with the global timer mode.

---

## Summary for tester(s) picking this up

The pilot was right: the unit-store tests don't cover restore, and the
restore logic that DOES exist sits in `services/reader-cache/`. Of the
six files I planned for, **`cache.test.ts` plus the un-tested
`pdf-cache.ts` / `epub-cache.ts` modules are the most actionable
surface**, followed at a distance by connectivity-service edge cases
(start-time reconcile, listener error isolation, post-stop isOnline).

Expect most output to land in `parity-gaps.md` and `practices-audit.md`,
not `findings/`. A real production-bug finding here needs a concrete
failing assertion — the discard-Promise-rejection in
`cache.ts:63 (void opts.destroy(...))` is the only candidate I see by
inspection, and only if a tester can demonstrate observable breakage.
