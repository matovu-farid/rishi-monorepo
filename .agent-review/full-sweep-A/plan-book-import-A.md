# Sub-Plan A — book-import renderer service tests

**Scope:** three Vitest files under
`apps/rishi-electron/src/renderer/src/services/book-import/`:
`dispatch.test.ts`, `emitter.test.ts`, `importer.test.ts`.

**Tester ID range:** A051-A060. Findings filed under
`.agent-review/full-sweep-A/findings/A05N-<slug>.md`. Cap 5 per spec.
Reviewer-1 alternation per pilot §4.4 (odd → team-reviewer,
even → feature-dev:code-reviewer).

---

## 1. Skip list

- `e2e/helpers/electron-app.ts` — pilot finding 011 already rejected
  this as a test-infra defect; do not refile.
- All e2e specs (other sub-plans own them).
- `src/main/ipc/formats.ts` and per-format extractors — cite by line
  only to substantiate a renderer-side contract gap.
- The production files `dispatch.ts`, `importer.ts`, `emitter.ts` —
  read only to spot-check; this sub-plan reviews the **tests**.

---

## 2. Dispatch-coverage gap check (persisted `kind` ↔ dispatched `format`)

Pilot finding 011 showed the e2e helper hardcodes `kind` and discards
the parser's `kind`, masking dispatcher misrouting. The renderer-side
unit tests should pin the contract.

**State of `dispatch.test.ts`:**
- `.epub` (L46-51): asserts both `result.format` and `result.data.kind`.
- `.azw3` (L69-75): asserts both. Good.
- `.pdf` (L55-60) and `.mobi` (L62-67): assert `result.format` ONLY.
  A regression returning `kind: 'epub'` from `getPdfData` would pass.
  **GAP.**
- No parameterized sweep asserting
  `result.format === result.data.kind` for all four formats.
- No negative test: if a parser returns a mismatched `kind`, what
  should dispatch do? Un-pinned. **GAP.**
- Case-insensitivity is only tested for `.EPUB` (L85-89), not
  `.PDF`/`.MOBI`/`.AZW3`.

**State of `importer.test.ts`:**
- Happy-path EPUB (L231-256) asserts `result.format` but NOT
  `savedBooks[0].kind`. The `makeDbForImport` fallback hardcodes
  `kind: 'epub'` (L47), so a `saveBook` payload that dropped `kind`
  would be masked. **GAP** (renderer-unit analogue of finding 011).
- No happy-path PDF/MOBI/AZW3 — per-format `Book.kind` propagation
  is unverified. **GAP.**

**Verdict:** there IS a contract-coverage gap; both files have it.
Strongest fix-worthy item: an `importer.test.ts` happy-path-per-format
sweep asserting `savedBooks[0].kind === <expected>`. Frame as a
coverage finding with a red mutation test on `importer.ts:153`
(swap `bookData.kind` for a literal), not as a production-bug finding
unless a tester can show a current path that misroutes today.

---

## 3. Per-file audit checklist

### 3.1 `dispatch.test.ts`

- L5-12 `sampleParsed` hardcodes `kind: 'epub'`; format overrides
  spread it. Document the convention.
- L43-51 vs L54-90 — asymmetric `describe` split (one EPUB-only block,
  one for the rest). Practice nit.
- L55-67 — PDF and MOBI assertions are weaker than EPUB/AZW3. See §2.
  **Fix-worthy.**
- L77-83 — unsupported-format test doesn't pin the error message;
  `importer.test.ts:116` consumes `/Unsupported format: \.txt/`, so
  the text IS contract.
- L85-89 — case-insensitivity tested for `.EPUB` only.
- Missing: parameterized `format === data.kind` sweep.
- Missing: edge paths (`/tmp/book` no extension, double extension,
  empty path).
- Missing: behavior when a format IPC rejects (dispatch never tested
  on the rejection path; importer covers `.epub` only).

### 3.2 `emitter.test.ts`

- L5-14, L16-27, L29-40 — three green-path tests. Acceptable scope
  for a tiny unit but contract is under-pinned.
- Missing: emit with zero subscribers (no-op contract).
- Missing: same listener subscribed twice (fires once or twice?).
- Missing: listener throws — does emit swallow or propagate? Matters
  for `importer.ts` progress resilience.
- Missing: unsubscribe twice (idempotent?).
- Missing: subscribe during emit (re-entrancy — new listener sees
  in-flight event?).
- No `beforeEach` reset since `createEmitter` is a factory — fine.

### 3.3 `importer.test.ts`

- L10 — imports `makeFormats` from `./dispatch.test`. Cross-file
  helper coupling; defensible, document.
- L39-73 — `makeDbForImport` fallback hardcodes `kind: 'epub'`.
  Caller's `b` wins on spread, but if `saveBook` payload dropped
  `kind`, the fallback masks it. See §2. **Fix-worthy.**
- L99-126 — unsupported-extension test covers the contract well.
- L128-152 — copy-failure test: add `expect(savedBooks).toEqual([])`
  for symmetry with §3.3 above.
- L154-181 — parse-failure rollback is EPUB-only; per-format mirrors
  would catch a format-specific rollback skip.
- L183-202 — save-failure path is EPUB-only.
- L204-229 — uses `setTimeout(r, 0)` to await the async upload-failed
  event. Prefer `vi.waitFor(...)`. Practice violation.
- L231-256 — happy-path EPUB does NOT assert
  `savedBooks[0].kind === 'epub'`. **Fix-worthy.**
- Missing: happy-path PDF/MOBI/AZW3 in `runImport`.
- Missing: `embedBatchSize` / `saveVectors` flow.
- Missing: `hasSavedEpubData` / `savePageDataMany` flow.
- Missing: timeout config (`parseTimeoutMs` et al.) — wired but never
  exercised. If a parser hangs, does the import fail with
  `stage: parse` or hang forever?

---

## 4. Test commands

From repo root:

```bash
pnpm --filter rishi-electron test src/renderer/src/services/book-import/dispatch.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/book-import/emitter.test.ts
pnpm --filter rishi-electron test src/renderer/src/services/book-import/importer.test.ts
```

Single test by name:

```bash
pnpm --filter rishi-electron test src/renderer/src/services/book-import/dispatch.test.ts -t "routes .pdf"
```

Flake check (≥3 runs) for any failing finding:

```bash
for i in 1 2 3; do pnpm --filter rishi-electron test src/renderer/src/services/book-import/<file>.test.ts -t "<name>" || echo "run $i: FAIL"; done
```

Verify discovery:

```bash
pnpm --filter rishi-electron test --reporter=verbose src/renderer/src/services/book-import/ | head -60
```
