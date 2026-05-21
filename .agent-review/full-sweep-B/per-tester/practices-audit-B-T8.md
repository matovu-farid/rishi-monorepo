# Practices Audit — Tester B-T8

Scope: `auth.spec.ts`, `import.spec.ts`, `library.spec.ts`.

Format: `<file>:<lines> :: <issue> :: <fix>`.

## Timing heuristics (replace with auto-wait or expect.poll)

- `auth.spec.ts:19` :: `waitForTimeout(300)` after hash navigation. ::
  Replace with `await expect(page.getByText(/sign in/i)).toBeVisible({ timeout: 10000 })`
  and drop the sleep.
- `auth.spec.ts:28` :: `waitForTimeout(1500)` after `reload()`. ::
  Replace with a positive landmark wait
  (`await expect(page.getByText('Welcome to Rishi')).toBeVisible({ timeout: 5000 })`)
  — already present at L29, so the sleep is redundant.
- `auth.spec.ts:38,43` :: Same pattern as L28. :: Same fix; sleep is
  redundant with the immediately-following `toBeVisible`.
- `library.spec.ts:28` :: `waitForTimeout(500)` after hash reset to
  `#/`. :: Wait for the library landmark
  (`[data-tour="book-grid"], text=No books yet`).
- `library.spec.ts:45,85-86,107,126-127` :: Five separate
  `reload() + waitForTimeout(1500)` pairs. :: Replace each with
  `await expect(page.locator('[data-tour="book-grid"]')).toBeVisible({ timeout: 10000 })`
  immediately after the reload.
- `library.spec.ts:92,97` :: `waitForTimeout(300)` after search input
  fill. :: Wait on the filtered grid state directly via
  `expect(page.locator('[data-tour="book-grid"] > div')).toHaveCount(N)`.
- `library.spec.ts:116` :: `waitForTimeout(1500)` after delete click.
  :: The very next assertion is `toHaveCount(0)`; drop the sleep —
  `toHaveCount` auto-retries.
- `library.spec.ts:61-70` :: Hand-rolled `Date.now()` polling loop with
  raw `waitForTimeout(100)` for the new book window. :: Replace with
  `await expect.poll(() => ctx.pages().some((p) => p.url().includes('/books/' + book.id)), { timeout: 10000 }).toBe(true)`.

## Selector hygiene

- `auth.spec.ts:20,30` :: `text=Sign In` vs `text=Sign in` for the same
  intent. :: Use `getByRole('button', { name: /sign in/i })` (or
  `getByRole('link', ...)` if it's a link). Filed as finding B101.
- `auth.spec.ts:29,39,41,44` :: `text=Welcome to Rishi`,
  `text=Maybe later` — copy-coupled. :: Add `data-testid`s to the
  welcome modal (`welcome-modal`, `welcome-modal-dismiss`) and switch.
- `library.spec.ts:32,91,96` :: `input[placeholder*="Search"]` —
  placeholder-coupled. :: Use `getByRole('searchbox')` or a
  `data-testid="library-search"`.
- `library.spec.ts:51,55,88,89,93,98,110,117` :: `text=<title>` for
  book rows. :: Use `getByRole('button', { name: <title> })` if the
  row exposes an accessible name; otherwise add
  `data-testid="book-row"` and `data-book-id`.
- `library.spec.ts:54-58` :: `[data-tour="book-grid"] > div ... button`
  reaches into a sibling DOM structure. :: Replace with a stable
  `getByRole` query on the row.
- `library.spec.ts:113` :: `getByRole('button', { name: 'Delete' })`
  with no scoping. :: Scope to the context menu role (`menu` /
  `menuitem`) or a confirm-modal role to disambiguate from any other
  Delete button on screen. Related: finding B103.

## Shared-state / isolation

- `auth.spec.ts:7-9` :: Shared `beforeAll(launchApp)` across three
  localStorage-mutating tests. Order-dependent. :: Switch to
  `beforeEach(launchApp)` + `afterEach(closeApp)`. Cost: ~2s/test.
- `library.spec.ts:15-29` :: Shared `beforeAll(launchApp)` with a
  shared book BrowserWindow leaked from test 2. :: Filed as finding
  B105; per-test launch.
- `import.spec.ts:16-26` :: Shared `beforeAll(launchApp)`. Acceptable
  here because `deleteAllBooks` runs in `beforeEach` and the spec does
  not open BrowserWindows, but the import-roundtrip test (L66-78)
  writes a hard-coded `'/import-roundtrip.pdf'` under the shared
  `getAppDataPath`. :: Either rename to include a unique suffix
  (`Date.now()`) or document the workers=1 assumption inline.

## Weak / loose assertions

- `import.spec.ts:34,44,54` :: `toMatchObject({ kind: '<x>' })` is a
  one-field check; title, author, cover length, page count, language,
  ISBN are unchecked. :: Strengthen to assert at least title-non-empty
  and cover length > 0 for fixtures where those are known.
- `import.spec.ts:63` :: `expect(['ok','warn']).toContain(result)`. ::
  Filed as finding B102; assert `expect(result).toBe('ok')` for a small
  fixture.
- `auth.spec.ts:41,44` :: `toHaveCount(0)` for the welcome modal text.
  :: Pair with a positive assertion that the library landmark
  (`[data-tour="book-grid"]` or the empty-library affordance) is
  visible, so a render crash that removes everything doesn't pass.

## Error-handling discipline

- `import.spec.ts:29-33,39-43,49-53` :: `page.evaluate` returns the IPC
  result with no try/catch; if the IPC throws, Playwright surfaces the
  error but with no spec-level context. Acceptable, but log the
  fixture path in the failure message for triage.

## Coverage observations (not findings)

- `library.spec.ts` :: `data-tour="book-grid"` is doubly-overloaded —
  it's both the onboarding tour target and the test's stable locator.
  If the tour target moves, library tests break. Consider separating
  `data-testid="book-grid"` from `data-tour="book-grid"`.
- `auth.spec.ts` :: No coverage of the auth-error surface (network
  failure during polling, token expired). Out of scope for this slice
  but parity-gap candidate; logged in parity-gaps file.
