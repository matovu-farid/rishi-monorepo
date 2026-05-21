# Plan — PDF Scroll Specs (Phase B, Planner P4 / Tester B-T4)

Scope: two PDF scroll-behavior e2e specs. Both active. Both rely heavily
on raw `waitForTimeout(...)` for setup pacing and hard-coded pixel
tolerances — the failure mode this phase is told to look hard for.

## 1. Skip List

None. Both files are in-scope and fully executable:

- `apps/rishi-electron/e2e/pdf-scroll-position.spec.ts` — 1 test, active.
- `apps/rishi-electron/e2e/pdf-scroll-up-jitter.spec.ts` — 1 test, active.

No `test.skip`, no `test.fixme`, no `test.only` in either file.

## 2. Per-File Audit Checklist

### 2.1 `e2e/pdf-scroll-position.spec.ts`

- **L31** `waitForTimeout(3000)` — cold-open settle. Brittle: depends on
  host CPU + PDF.js worker init. Prefer `expect.poll` on a renderer
  ready signal (first `canvas.react-pdf__Page__canvas` visible).
- **L38** `scrollTo({ top: 6500 })` — magic number tied to the fixture's
  per-page measured height. Verify fixture stability (`PDF_FIXTURE` in
  `e2e/helpers/electron-app.ts`).
- **L41** `toBeGreaterThan(6000)` — guard, acceptable.
- **L44** `waitForTimeout(1500)` — claims to cover "scroll listener
  (80ms) + persist debounce (400ms) + IPC margin". Those 80/400
  constants are load-bearing; if they drift, the 1500 wait silently
  breaks. Cross-check against the real values in pdfStore subscription
  and `books:updateLocation` IPC.
- **L49** `toMatch(/^\d+:\d+/)` — encodes the wire format ("page:offset").
  Compare against what `src/main/ipc/books.ts` actually writes. If the
  separator drifted in production, this is a real finding.
- **L61** `waitForTimeout(1500)` post-close — poll on `app.context().pages()`
  instead.
- **L63** `waitForTimeout(4000)` post-reopen — biggest brittle wait;
  poll on reader-ready.
- **L77-81** `tolerance = 450` — comment justifies it, but 450px is
  huge. A silent ~300px restore drift would pass while users see a
  visible jump. Consider asserting page index exactly and allowing
  slack only on the sub-page offset.
- **Gap**: no assertion on the *displayed* page number after reopen,
  only `scrollTop`. A right-pixel/wrong-page bug slips through.

### 2.2 `e2e/pdf-scroll-up-jitter.spec.ts`

- **L38** `waitForTimeout(3000)` — same cold-open issue.
- **L45** `scrollTo({ top: 14000 })` — magic. Test depends on this
  truly unmounting pages above; verify fixture is tall enough.
- **L47** `waitForTimeout(2500)` — should poll virtualizer measured
  state or canvas count stabilizing.
- **L54** `target = scrollTop - 600` — assumes 600px crosses a page
  boundary. If fixture orientation changes, this silently no longer
  exercises the remount path.
- **L57-65** 600ms sampling loop at 16ms — this IS the assertion
  mechanism, not setup pacing. `setTimeout(r, 16)` here is correct.
  Defend; do NOT flag as a `waitForTimeout` violation.
- **L77** `toBeLessThan(80)` — 80px jitter threshold. If the original
  bug was 200px and the fix overshoots to 90px, this test misses a
  partial regression. Probe git history for the bug magnitude.
- **Gap**: no diagnostic asserting pages were actually unmounted
  before the scroll-up (e.g. `canvas` count < N at L48). If overscan
  ever changes, the test no longer exercises remount.
- **Gap**: single 600ms sample window. A late-frame jitter (>600ms)
  is invisible.

Cross-file practice observations:

- Both use top-level `test(...)`, consistent with other PDF specs. OK.
- Both rely on `div.overflow-y-scroll` (structural CSS) for the
  container. A DOM refactor breaks both silently. Consider a
  `data-testid`. Practice observation.
- Per-test `launchApp` / `closeApp` with tmp userDataDir — correct
  isolation.

Triage:

- *Finding* = production code produces wrong user-visible behavior.
  If a run reveals a broken save format, wrong sub-page restore, or
  back-jump >80px on current main, file under `findings/`.
- `waitForTimeout` cases above → `practices-audit.md`.
- Missing page-number-after-reopen / unmount diagnostic → `parity-gaps.md`.

## 3. Tester ID Range

Tester B-T4. IDs **B046 – B055** (10 slots; cap 5 per spec).

- `pdf-scroll-position.spec.ts` → B046-B050.
- `pdf-scroll-up-jitter.spec.ts` → B051-B055.

Reviewer-1 alternation per `FINDING-TEMPLATE.md` rule on trailing digit:
odd → `team-reviewer`, even → `feature-dev:code-reviewer`. File path:
`.agent-review/full-sweep-B/findings/B0NN-<slug>.md`.

## 4. Test Commands

Build prerequisite (Playwright entry: `../../out/main/index.js`):

```bash
pnpm --filter rishi-electron build
```

Run each spec from `apps/rishi-electron`:

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/pdf-scroll-position.spec.ts
pnpm test:e2e e2e/pdf-scroll-up-jitter.spec.ts
```

Flake check (≥3 runs; jitter test is more flake-prone):

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e e2e/pdf-scroll-up-jitter.spec.ts || echo "run $i: FAIL"; done
for i in 1 2 3; do pnpm test:e2e e2e/pdf-scroll-position.spec.ts || echo "run $i: FAIL"; done
```

Discovery sanity:

```bash
pnpm test:e2e --list e2e/pdf-scroll-position.spec.ts
pnpm test:e2e --list e2e/pdf-scroll-up-jitter.spec.ts
```

Grep production constants before citing them:

```bash
rg -n "scroll|debounce" apps/rishi-electron/src/renderer/src/stores/pdfStore.ts
rg -n "updateLocation|saveLocation" apps/rishi-electron/src/main/ipc/books.ts
```
