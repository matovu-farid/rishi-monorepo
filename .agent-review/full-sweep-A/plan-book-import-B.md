# Plan B — book-import service-layer test review

Companion to `plan-book-import-A.md`. Scope: 3 service-layer Vitest files
covering the orchestrator (`service.ts`), the scanner IPC adapter
(`scanner-adapter.ts`), and the embed/index pipeline (`indexer.ts`).

## 1. Skip list

No `it.skip` / `describe.skip` / `.only` in the assigned 3 files — all
tests active. The fixtures imported from `dispatch.test.ts` and
`importer.test.ts` belong to Plan A; do not double-cover.

## 2. Per-file audit checklist

### 2.1 `src/renderer/src/services/book-import/indexer.test.ts`

- Mocking `db`/`rag`/`embed` is correct — these are injected dependencies,
  not the SQLite/fs real-only boundaries (pilot §3.5). Do NOT file a
  finding demanding real `better-sqlite3` here.
- **L88-108 vector name `'42-vectordb'`** — verify against `indexer.ts`
  source; if production uses a different naming scheme, real bug.
- **L99 `expect(savePageDataCalls).toHaveLength(2)`** asserts COUNT only.
  Production could save 2 rows with wrong `bookId`/`pageNumber` and still
  pass. Weak content assertion — `practices-audit.md`.
- **L131-145 "embed failure swallowed"** — confirm in `indexer.ts` that
  the catch block actually exists; if real code propagates, the test
  enshrines a wrong contract. High-value spelunking target.
- **L169-183** only `find`s the FIRST `indexed` event. Order-sensitive,
  borderline practice violation.
- **Missing: `savePageDataMany` rejection path.** `makeDb` wires `failOn`
  (L24) but no test exercises it. Coverage gap likely hiding a real bug.
- **Missing: `saveVectors` rejection path.** Same — `failOn` wired but
  unused. Partial-failure (chunks saved, vectors failed) is uncovered.
- **`embedBatchSize: 2` with exactly 2 rows** — batching boundary never
  stressed. Try 3 rows / 0 rows. Coverage gap.
- **No assertion `rag.isIndexed` was actually consulted** in the
  fully-indexed path. Drift to a single check undetectable.

### 2.2 `src/renderer/src/services/book-import/scanner-adapter.test.ts`

- Adapter wraps contextBridge IPC; fake at L9-46 is appropriate (real
  boundary unreachable from Vitest). No real-only violation.
- **L48-58 forward-only assertion via `startCalls` arrays** IS call-count
  theater, but defensible: forwarding is the entire job. Do not file.
- **L60-79, L81-98 result/unsubscribe** — strong behavior assertions.
  Defend.
- **Missing: multi-listener fan-out.** Two callers on `'result'` — both
  receive? If production uses a single-slot ref, bug invisible here.
- **Missing: listener cleanup on adapter teardown.** No dispose/GC test.
  Low-severity coverage gap.
- **Missing: malformed payload.** `null` or wrong shape on `scan-result`
  — adapter likely passes through; downstream crashes. One negative test
  would catch it.
- **L12 channel list hard-coded to 3 channels.** New IPC channel
  (e.g. `scan-error`) won't be dispatched — fixture coupling note.

### 2.3 `src/renderer/src/services/book-import/service.test.ts`

- **L11-13 cross-file fixture imports** from sibling `*.test.ts` files
  (no `__fixtures__/` module). Fragile if siblings are deleted.
  `practices-audit.md`.
- **L112-135 happy path** asserts event ORDER — meaningful contract.
  But the `await new Promise(r => setTimeout(r, 0))` at L124-126 to
  wait for `upload-started` smells like an unawaited promise in
  production. **Possible real bug** — verify whether `upload-started`
  should be awaitable from `importFromPath`.
- **L137-157 importBatch** — strong order + ok/err behavior assertion.
  Defend.
- **L159-244 indexBook suite** mostly duplicates `indexer.test.ts` via
  the service facade. Several pure `expect(db.X).toHaveBeenCalledTimes(N)`
  assertions are call-count theater — service-level should ALSO assert
  the emitted `ImportProgressEvent` stream or final state.
- **L221-243 isIndexing in-flight** — excellent deferred-embed pattern.
  Defend.
- **L246-275 startDiscovery** — kind-sequence assertion is
  behavior-focused. Defend.
- **L277-287 single-flight** — counts ARE the behavior here. Acceptable.
- **L289-300 cancelDiscovery uses `toContainEqual`** — permits stray
  events. Production could emit a second `complete: cancelled=false`
  after the cancelled one and still pass. Weak matcher — practice
  violation.
- **L312-327 unsubscribe via delta** — correct pattern. Defend.
- **Missing: re-entrancy of `importFromPath`.** Concurrent same-path
  calls — clobber? Dedupe? Drag-drop dupes likely hit this.
- **Missing: service teardown / disposal.** Re-creating the service
  (logout/login) — do subscriptions leak?
- **Missing: orchestrator-level error propagation.** When the underlying
  `importer` rejects, does the service emit a terminal `error` event?
  Coordinate with Plan A to avoid double-coverage gap.

## 3. Tester ID range

Findings filed from this plan use IDs **A061-A070**. Per-spec cap of 5
findings still applies. Reviewer-1 alternation (pilot §4.4): odd ID →
`team-reviewer`, even ID → `feature-dev:code-reviewer`.

## 4. Test commands

Vitest only — none of these are Playwright. Renderer suite is `happy-dom`
(pilot §3.1).

### Per-file

```bash
pnpm --filter rishi-electron test src/renderer/src/services/book-import/indexer.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/book-import/scanner-adapter.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/book-import/service.test.ts
```

### Single test by name

```bash
pnpm --filter rishi-electron test src/renderer/src/services/book-import/service.test.ts \
  -t "isIndexing reflects in-flight state"
```

### Whole book-import directory

```bash
pnpm --filter rishi-electron test src/renderer/src/services/book-import
```

### Flake check (Reviewer-1, ≥3 runs)

```bash
for i in 1 2 3; do
  pnpm --filter rishi-electron test \
    src/renderer/src/services/book-import/service.test.ts \
    -t "<name>" || echo "run $i: FAIL"
done
```

### Discovery sanity

```bash
pnpm --filter rishi-electron test --reporter=verbose \
  src/renderer/src/services/book-import/indexer.test.ts | head -40
```
