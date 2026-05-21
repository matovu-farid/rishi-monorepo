# Practices Audit — B-T9 (smoke, no-toolbar, mobi-global-page-counter, scanner)

Tester: B-T9
Date: 2026-05-20

Practice-level findings (test quality, not production bugs). Severity
is `info | low | med`. None warrant a `findings/` entry on their own.

---

## smoke.spec.ts

### PA-T9-01 — Empty-library copy is tightly coupled to product strings — low
- `apps/rishi-electron/e2e/smoke.spec.ts:22-23` asserts
  `text=No books yet` and `text=drag and drop`. Any copy change
  breaks smoke. Prefer `data-testid="empty-library"` /
  `data-testid="empty-library-hint"` to decouple from marketing copy.
- Accepted limitation per plan §2.4 (smoke = wide+shallow), but
  documented here for the next refactor of the empty state.

### PA-T9-02 — IPC surface inventory is presence-only, not contract — info
- `apps/rishi-electron/e2e/smoke.spec.ts:26-47` checks
  `typeof === 'function'` for 11 IPC names. Catches renames; misses
  signature drift (arg count/types, return shape). By design — smoke,
  not contract — but worth noting that the matching `import.spec.ts`
  & `library.spec.ts` are the de-facto contract layer and must stay
  honest about it.

---

## no-toolbar.spec.ts

### PA-T9-03 — `waitForTimeout(1500)` after openBook — low
- `apps/rishi-electron/e2e/no-toolbar.spec.ts:9` sleeps 1.5s after
  `openBook`. Replace with an auto-wait against a stable reader
  landmark, e.g.
  `await bookPage.locator('iframe, canvas').first().waitFor({ state: 'visible' })`
  or `await bookPage.locator('[data-testid="reader-content"]').waitFor()`.
  The current sleep is both slower-than-needed in CI and racier than
  necessary on slow hardware.

---

## mobi-global-page-counter.spec.ts

### PA-T9-04 — `waitForTimeout(500)` settle is inconsistent with the rest of the spec — low
- `apps/rishi-electron/e2e/mobi-global-page-counter.spec.ts:31-32`.
  Every other observation in this spec is a `expect.poll` against
  `data-current`. This single bare 500ms wait is the one inconsistency.
  Replace with
  `await expect.poll(async () => Number(await counter.getAttribute('data-current'))).toBeGreaterThanOrEqual(1)`
  so initial-measurement settling uses the same idiom as the loop.

### PA-T9-05 — `test.setTimeout(90000)` likely larger than necessary — info
- `apps/rishi-electron/e2e/mobi-global-page-counter.spec.ts:15`.
  After a runtime measurement (≥3 CI runs), tighten the budget to
  roughly 2× the observed P95 so a slow-chapter regression surfaces
  as a fail rather than a 90s wait.

### PA-T9-06 — MOBI test depends on AZW3-named testid — info
- `apps/rishi-electron/e2e/mobi-global-page-counter.spec.ts:25` uses
  `[data-testid="azw3-page-counter"]` for a MOBI viewer. Internal
  coupling: if the AZW3/MOBI shared component is renamed or split,
  the MOBI test breaks even though MOBI behavior is unchanged.
  Either rename the testid to `epub-like-page-counter` (format-neutral)
  or add a MOBI-specific alias.

---

## scanner.spec.ts

### PA-T9-07 — `beforeEach` defensive cleanup hides race conditions — med
- `apps/rishi-electron/e2e/scanner.spec.ts:15-28`. Sequence is
  Escape → `waitForTimeout(200)` → conditional Cancel click →
  `waitForTimeout(300)` → hash reset → `waitForTimeout(300)`. Three
  bare sleeps in setup is a smell — if any of them is shorter than
  the real settle time, the *next* test sees stale state and fails
  for a non-obvious reason. Extract a `closeAllModals(page)` helper
  that waits on a deterministic "modal-closed" signal
  (`expect(page.locator('[role="dialog"]')).toHaveCount(0)`).

### PA-T9-08 — `text=/Scanning/i` is copy-coupled — low
- `apps/rishi-electron/e2e/scanner.spec.ts:45`. Regex on user-visible
  copy. Prefer `[data-testid="scan-indicator"]` (add if absent). The
  scanning indicator is a stable UI element with a clear semantic — it
  earns a testid.

### PA-T9-09 — Cancel assertion uses `toHaveCount(0)` on the same selector that may also match background text — low
- `apps/rishi-electron/e2e/scanner.spec.ts:58` asserts
  `text=Common folders` has `toHaveCount(0)` after Cancel. If "Common
  folders" appears in any other surface (sidebar, tooltip), this
  assertion silently weakens. Prefer a dialog-scoped assertion:
  `await expect(page.getByRole('dialog')).toHaveCount(0)`.

---

## Shared-state observations

### PA-T9-10 — Shared `beforeAll(launchApp)` in smoke & scanner — info
- Both `smoke.spec.ts` and `scanner.spec.ts` share one Electron
  instance across all `test()` blocks. For smoke (read-only) this is
  fine. For scanner (opens modals, mutates hash, presses Escape) the
  per-test cleanup PA-T9-07 is the only thing keeping ordering from
  mattering — and the bare-sleep cleanup is itself fragile. Either
  switch scanner to per-test `launchApp` or harden the cleanup.
