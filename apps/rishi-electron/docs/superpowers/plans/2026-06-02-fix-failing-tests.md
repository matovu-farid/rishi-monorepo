# Fix Failing Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore a green test suite by (1) reverting the offscreen-window change suspected of breaking Playwright E2Es, (2) triaging remaining failures into "broken / needs-update / fixture-flake", (3) fixing or updating each, (4) un-skipping deferred specs, and (5) adding tests for untested new code shipped in the sharing/PDF/player work.

**Architecture:** Two test runners co-exist: `vitest run` (unit/integration, see `vitest.config.ts`) and `playwright test` (E2E against the built Electron app, see `playwright.config.ts` + `playwright.sharing.config.ts`). The E2E helper at `e2e/helpers/electron-app.ts` launches Electron with `RISHI_E2E_HIDDEN=1` by default, and main reads that flag in `src/main/windows/createBrowserWindow.ts` to park windows offscreen and skip `win.show()`. Reverting that flag back to a regular visible window (with `win.show()` always called) is the first hypothesis to validate before any per-test work.

**Tech Stack:** Vitest 2.1.9, Playwright (electron driver), Electron 38+, electron-vite, TypeScript, XState v5 for player/session state.

---

## Phase 0 — Revert the offscreen-window change (single hypothesis test)

**Why this is Phase 0:** A whole class of "renderer didn't paint / event didn't fire / element not visible" failures collapses into one explanation if the hidden-window patch is the cause. Revert first, re-run, then triage what remains. This avoids fixing tests against the wrong baseline.

### Task 0.1: Revert offscreen-window flag in createBrowserWindow

**Files:**
- Modify: `src/main/windows/createBrowserWindow.ts:11-49`

- [ ] **Step 1: Revert window-hiding logic to pre-#253 behavior**

Replace the `hidden`-conditional block so `BrowserWindow` is always constructed without the `-10000`/`skipTaskbar` overrides and `ready-to-show` always calls `win.show()`.

```ts
// src/main/windows/createBrowserWindow.ts (snippet)
export function makeBrowserWindowFactory(deps: FactoryDeps) {
  return (identity: WindowIdentity): BrowserWindow => {
    const dims =
      identity.kind === 'settings'
        ? { width: 640, height: 720 }
        : identity.kind === 'library'
          ? { width: 1024, height: 770 }
          : { width: 1100, height: 900 }

    const win = new BrowserWindow({
      width: dims.width,
      height: dims.height,
      minWidth: identity.kind === 'settings' ? 480 : 800,
      minHeight: identity.kind === 'settings' ? 480 : 600,
      titleBarStyle: 'hiddenInset',
      trafficLightPosition: { x: 15, y: 10 },
      show: false,
      webPreferences: {
        preload: deps.preloadPath,
        sandbox: false,
        contextIsolation: true,
        nodeIntegration: false,
        webSecurity: identity.kind === 'book' ? false : true,
        additionalArguments: [`--window-identity=${identityFlag(identity)}`]
      }
    })
    win.on('ready-to-show', () => win.show())
    // …rest of file unchanged…
```

Delete lines 20-23 (the `// Park e2e windows offscreen…` comment block and the `hidden` const), delete line 33 (the spread of x/y/skipTaskbar), and unconditional-ize line 49 to `win.on('ready-to-show', () => win.show())`.

- [ ] **Step 2: Drop RISHI_E2E_HIDDEN from launch envs**

`e2e/helpers/electron-app.ts` injects `RISHI_E2E_HIDDEN` in two places: `launchApp` (line 34) and `launchAppWithSharingEnv` (line 402). Remove both env keys (and the `RISHI_E2E_HEADED` reference inside them — keep the npm scripts that set `RISHI_E2E_HEADED=1` alone for now; with the revert done they become no-ops, and a follow-up commit can clean them up if desired).

```ts
// In launchApp:
const app = await electron.launch({
  args: [MAIN_ENTRY, `--user-data-dir=${userDataDir}`],
  env: {
    ...process.env,
    NODE_ENV: 'production'
  }
})

// In launchAppWithSharingEnv: same — drop RISHI_E2E_HIDDEN line, keep the rest.
```

- [ ] **Step 3: Re-run a fast E2E to validate the hypothesis**

Run a single canonical reader spec that previously worked, headed off:

```bash
pnpm exec playwright test e2e/smoke.spec.ts -x --reporter=line
```

Expected: pass. If it fails for unrelated reasons, capture the failure but proceed — Phase 1 will catalog everything.

- [ ] **Step 4: Commit**

```bash
git add src/main/windows/createBrowserWindow.ts e2e/helpers/electron-app.ts
git commit -m "revert(electron/e2e): drop RISHI_E2E_HIDDEN offscreen-window mode

The offscreen window introduced in #253 throttles the renderer
(background-tab heuristics) and changes layout/focus semantics
enough to cascade E2E failures across PDF/EPUB/menu specs.
Restore the pre-#253 always-visible window for the e2e harness."
```

---

## Phase 1 — Discover the post-revert test landscape

### Task 1.1: Capture vitest baseline

**Files:**
- Create: `.test-reports/vitest-baseline.txt` (gitignored — `.test-reports/` is already covered by `49d12fe1`'s `.gitignore` updates if present; if not, add it)

- [ ] **Step 1: Run vitest non-watch and capture output**

```bash
mkdir -p .test-reports
pnpm test 2>&1 | tee .test-reports/vitest-baseline.txt
```

Expected: at least produces a deterministic pass/fail report. Tests run via `vitest run`.

- [ ] **Step 2: Extract failures into a structured list**

From the captured output, produce `.test-reports/vitest-failures.md` with one bullet per failing test:

```
- <file>:<line> — <test name> — <one-line failure summary>
```

Group by file. Don't include full stack traces. If a whole file fails to import, list it separately under "Collection failures".

- [ ] **Step 3: Commit the failure list (not the raw log)**

```bash
git add .test-reports/vitest-failures.md
git commit -m "chore(tests): snapshot vitest failures for triage"
```

### Task 1.2: Capture playwright baseline

**Files:**
- Create: `.test-reports/playwright-baseline.txt`
- Create: `.test-reports/playwright-failures.md`

- [ ] **Step 1: Ensure native modules are built for production runtime**

The pretest:e2e hook already runs `scripts/ensure-native-abi.cjs`. Make sure the prod build is current:

```bash
pnpm run build
```

Expected: `out/main/index.js` and `out/renderer/index.html` exist and are fresh.

- [ ] **Step 2: Run the standard playwright config**

```bash
pnpm exec playwright test --reporter=list 2>&1 | tee .test-reports/playwright-baseline.txt
```

Expected: produces pass/fail per spec. No watch mode. Trace-on-first-retry is already set.

- [ ] **Step 3: Run the sharing config separately**

```bash
pnpm run test:e2e:sharing --reporter=list 2>&1 | tee -a .test-reports/playwright-baseline.txt
```

- [ ] **Step 4: Extract failures into a structured list**

Produce `.test-reports/playwright-failures.md`:

```
- <spec-file>:<line> — <test name> — <one-line failure summary>
```

- [ ] **Step 5: Commit**

```bash
git add .test-reports/playwright-failures.md
git commit -m "chore(tests): snapshot playwright failures for triage"
```

### Task 1.3: Catalog skipped specs

**Files:**
- Create: `.test-reports/skipped-tests.md`

- [ ] **Step 1: Grep for hard skips and todos across e2e/ and src/**

```bash
rg -n --no-heading -e '\btest\.(skip|fixme|todo)\(' \
  -e '\b(it|describe)\.(skip|todo)\(' \
  -e '\bxit\(' -e '\bxtest\(' \
  e2e src > .test-reports/skipped-tests.md
```

Expected: produces a flat list. From the current tree, expect at minimum:
- `e2e/pdf-warm-restore.spec.ts:33` — `test.skip('reopening a PDF…')`
- `e2e/epub-cache-no-flash.spec.ts:28` — `test.skip('warm-restore reopen…')`
- `e2e/epub-warm-restore.spec.ts:69` — `test.skip('first open populates the cache…')`
- `e2e/pdf-footer-detection.spec.ts:103` — `test.fixme('masked items live in the bottom band')`
- Conditional `test.skip(true, …)` and `test.fixme(true, …)` inside spec bodies — categorize these separately because they are runtime fixture guards, not the same as unconditional `test.skip(name, fn)`.

- [ ] **Step 2: Sort the list into two buckets in the same file**

Edit `.test-reports/skipped-tests.md` so it has two headed sections:

```md
## Unconditionally skipped (must un-skip in Phase 3)
- e2e/pdf-warm-restore.spec.ts:33 — reopening a PDF hits the warm-restore cache
- e2e/epub-cache-no-flash.spec.ts:28 — warm-restore reopen does not flash inner loading view
- e2e/epub-warm-restore.spec.ts:69 — first open populates the cache, second open hits it
- e2e/pdf-footer-detection.spec.ts:103 — masked items live in the bottom band

## Conditional runtime-guard skips (review, do not auto-fix)
- e2e/read-aloud-from-selection.spec.ts:97 — fixme when no paragraphs published
- e2e/read-aloud-from-selection.spec.ts:167 — fixme when player still idle
- e2e/read-aloud-from-selection.spec.ts:233 — fixme on selection failure
- e2e/menu-commands.spec.ts:66 — skip when bookSyncId is missing
- e2e/epub-reader.spec.ts:59 — skip when no TOC toggle in the build
- e2e/navigation-history-pdf.spec.ts:148,228 — skip when test PDF is too short
- e2e/navigation-history-epub.spec.ts:98,121 — skip when no TOC in fixture
```

- [ ] **Step 3: Commit**

```bash
git add .test-reports/skipped-tests.md
git commit -m "chore(tests): catalog skipped specs"
```

---

## Phase 2 — Triage: broken vs needs-update vs flake

### Task 2.1: Classify each vitest failure

**Files:**
- Modify: `.test-reports/vitest-failures.md` (add classification column)

- [ ] **Step 1: For each failing vitest test, decide one of three labels**

For each entry, look at: (a) the assertion message, (b) the file's git history (`git log -p -- <file>`), (c) the production code paths it covers. Label:

- `BROKEN` — production code is wrong; test is correct; fix the code.
- `STALE` — test asserts old behavior that the production code intentionally changed; update the test to match new contract.
- `FLAKE` — passes locally on second run, no determinism guarantee; mark with `FLAKE` and a one-line rationale.

Rewrite `.test-reports/vitest-failures.md` so each bullet ends with ` — [BROKEN|STALE|FLAKE] — <reason>`.

- [ ] **Step 2: Commit the classification**

```bash
git add .test-reports/vitest-failures.md
git commit -m "chore(tests): classify vitest failures"
```

### Task 2.2: Classify each playwright failure

Same procedure for `.test-reports/playwright-failures.md`. Pay particular attention to specs that newly pass after the Phase 0 revert — those are not failures anymore.

- [ ] **Step 1: Re-run failing-only**

```bash
pnpm exec playwright test --last-failed --reporter=line 2>&1 | tee .test-reports/playwright-last-failed.txt
```

- [ ] **Step 2: Classify each remaining failure** as `BROKEN`, `STALE`, or `FLAKE` with rationale. Update `.test-reports/playwright-failures.md`.

- [ ] **Step 3: Commit**

```bash
git add .test-reports/playwright-failures.md .test-reports/playwright-last-failed.txt
git commit -m "chore(tests): classify playwright failures"
```

---

## Phase 3 — Fix tests (one commit per fix)

**Rule:** TDD discipline. For `BROKEN`: write the test (it already exists and is red) → run it red → fix production code → run green → commit. For `STALE`: change the test assertions to match the new contract, run red→green by adjusting test only, commit. For `FLAKE`: pin determinism (replace `waitForTimeout` with `expect.poll`, await known events, etc.) — never just retry.

### Task 3.1: Un-skip unconditionally-skipped specs

For each entry in the "Unconditionally skipped" section of `.test-reports/skipped-tests.md`:

- [ ] **Step 1: Remove the `.skip` / `.fixme` modifier**

`e2e/pdf-warm-restore.spec.ts:33`:

```ts
// Before
test.skip('reopening a PDF hits the warm-restore cache and renders pages', async () => {

// After
test('reopening a PDF hits the warm-restore cache and renders pages', async () => {
```

Apply the same change to:
- `e2e/epub-cache-no-flash.spec.ts:28`
- `e2e/epub-warm-restore.spec.ts:69`
- `e2e/pdf-footer-detection.spec.ts:103` (replace `test.fixme(` with `test(`)

- [ ] **Step 2: Run each un-skipped spec individually**

```bash
pnpm exec playwright test e2e/pdf-warm-restore.spec.ts --reporter=line
pnpm exec playwright test e2e/epub-cache-no-flash.spec.ts --reporter=line
pnpm exec playwright test e2e/epub-warm-restore.spec.ts --reporter=line
pnpm exec playwright test e2e/pdf-footer-detection.spec.ts --reporter=line
```

- [ ] **Step 3: For each that fails, classify (`BROKEN` vs `STALE`) and fix per Phase 3.2/3.3.**

- [ ] **Step 4: For each that passes, commit the un-skip standalone**

```bash
git add e2e/<spec-file>
git commit -m "test(e2e): un-skip <spec-name>"
```

### Task 3.2: Fix BROKEN tests

For each entry classified `BROKEN`:

- [ ] **Step 1: Reproduce the failure in isolation**

```bash
pnpm exec playwright test <spec-file> -g "<test name>" --reporter=line
# or for vitest:
pnpm exec vitest run <file> -t "<test name>"
```

Expected: red, matching the captured failure message.

- [ ] **Step 2: Diagnose the production-code root cause**

Read the test, read the production code under test, identify the contract the test asserts, and find where the production code diverges. If the diagnosis takes more than ~10 minutes of reading, dispatch the work to `Agent({ subagent_type: "systematic-debugging" })` with the test, the failure, and the production code paths.

- [ ] **Step 3: Write the minimal production fix**

Edit only the file(s) needed to make the assertion true. No drive-by refactors. No additional features.

- [ ] **Step 4: Re-run the single test green, then the whole suite green**

```bash
pnpm exec playwright test <spec-file> -g "<test name>" --reporter=line
# or for vitest:
pnpm exec vitest run <file> -t "<test name>"

# then full suite
pnpm exec playwright test --reporter=line  # or pnpm test
```

- [ ] **Step 5: Commit**

```bash
git add <fixed-files>
git commit -m "fix(<scope>): <one-line problem statement>

Test <spec-file>:<line> asserts <contract>. Production code at
<file>:<line> previously did <wrong thing>; now does <right thing>."
```

### Task 3.3: Update STALE tests

For each entry classified `STALE`:

- [ ] **Step 1: Read the current production behavior and the test's assertions**

Identify exactly which assertion(s) no longer match. The commit(s) that changed the production contract should be findable with `git log -S '<symbol>' -- <file>`.

- [ ] **Step 2: Update the test to assert the new contract**

Keep the test's intent (what behavior is it pinning?) the same. Don't water it down — if the new contract makes the original property impossible to observe, replace it with the strongest equivalent observation, not a tautology.

- [ ] **Step 3: Run green and commit**

```bash
pnpm exec playwright test <spec-file> --reporter=line  # or vitest
git add <test-file>
git commit -m "test(<scope>): update <spec-name> to new <feature> contract"
```

### Task 3.4: Stabilize FLAKE tests

For each entry classified `FLAKE`:

- [ ] **Step 1: Identify the source of nondeterminism**

Most common in this repo: `page.waitForTimeout(N)` used as a substitute for an event; races between IPC and renderer state; fixture-timing assumptions.

- [ ] **Step 2: Replace timing with positive assertions**

Patterns: `expect.poll(() => …).toBe(…)`, `page.waitForFunction(…)`, `app.evaluate(({ ipcMain }) => …)`, awaiting `'console'` / `'pageerror'` events.

- [ ] **Step 3: Run the test 5× to confirm stability**

```bash
for i in 1 2 3 4 5; do pnpm exec playwright test <spec> -g "<name>" --reporter=line || break; done
```

Expected: 5 green runs in a row.

- [ ] **Step 4: Commit**

```bash
git add <test-file>
git commit -m "test(e2e): stabilize <test name> with deterministic waits"
```

---

## Phase 4 — Write tests for new untested code

Scope: code introduced in the recent run (sharing #253, player Phase 3 #252, PDF footer/jitter cluster) that has no test coverage. Untested file ≠ untested behavior — only add tests for behavior that has no covering test anywhere.

### Task 4.1: Coverage map of recent changes

**Files:**
- Create: `.test-reports/untested-new-code.md`

- [ ] **Step 1: Enumerate files touched by the recent merges**

```bash
git log --name-only --since='2026-04-01' --pretty=format: -- 'src/**/*.ts' 'src/**/*.tsx' \
  | sort -u | grep -v -E '\.test\.|/__tests__/|\.spec\.' > .test-reports/recent-src-files.txt
```

- [ ] **Step 2: For each file, look for a matching test**

```bash
while read -r f; do
  base=$(basename "$f" | sed -E 's/\.(ts|tsx)$//')
  hits=$(rg -l "$base" e2e src --type ts --type tsx | grep -E '\.(test|spec)\.' | wc -l | tr -d ' ')
  echo "$hits $f"
done < .test-reports/recent-src-files.txt | sort -n > .test-reports/coverage-map.txt
```

- [ ] **Step 3: Write `untested-new-code.md` listing files with `0` test references**

Group by subsystem (sharing, player, pdf, db). For each, write one sentence on what behavior is untested.

- [ ] **Step 4: Commit**

```bash
git add .test-reports/untested-new-code.md .test-reports/coverage-map.txt
git commit -m "chore(tests): map untested code added in recent merges"
```

### Task 4.2: Write tests for high-risk untested behavior

**Rule:** Don't aim for coverage; aim for risk reduction. Pick the 5–10 highest-risk behaviors from Task 4.1 (sharing IPC validation, DB migrations, XState actor invariants, file-transfer hash checks) and add one focused test per behavior. Prefer integration over unit when the behavior crosses module seams.

For each high-risk behavior:

- [ ] **Step 1: Write the test red**

Decide unit-vs-integration. Sharing IPC and DB migrations should be vitest integration tests against an in-memory DB. XState actors should be vitest unit tests using `createActor` from `xstate`. Renderer-side flows should be Playwright E2E only when they can't be reasonably exercised at unit level.

- [ ] **Step 2: Run it red**

Expected: fails because the assertion would fail under current code or because the test file is brand new.

- [ ] **Step 3: If the test exposes a real bug**, fix the bug under TDD — write the fix, re-run green, commit. If the test passes immediately, that's fine — it pins existing correct behavior.

- [ ] **Step 4: Commit one test per behavior**

```bash
git add <new-test-file>
git commit -m "test(<scope>): pin <behavior>"
```

### Task 4.3: Final full-suite green run

- [ ] **Step 1: Run everything**

```bash
pnpm test && pnpm exec playwright test --reporter=line && pnpm run test:e2e:sharing --reporter=line
```

Expected: all three green.

- [ ] **Step 2: Tag the milestone (optional)**

```bash
git tag -a tests-green-$(date +%Y-%m-%d) -m "All unit + E2E + sharing E2E green"
```

---

## Notes for the executor

- Do not run anything that calls `git push` or pushes tags unless the user explicitly asks.
- The `pretest` hook (`pnpm rebuild:node`) and `pretest:e2e` hook (`scripts/ensure-native-abi.cjs`) take 30–90s the first time. Don't kill them.
- Playwright traces land in `test-results/`; if a test fails after Phase 3 fixes, open the trace with `pnpm exec playwright show-trace test-results/<…>/trace.zip` instead of staring at logs.
- If a test fails *only* in `RISHI_E2E_HEADED=0` (CI-like) after Phase 0 revert, that's a real flake, not the offscreen-window regression. Treat it under Task 3.4.
- One commit per logical fix. Never bundle "fix three unrelated tests" into one commit — bisect-hostile.
