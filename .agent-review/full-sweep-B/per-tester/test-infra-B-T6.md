# Test Infrastructure Notes — Tester B-T6 (Menu specs, P6)

Scope: cross-cutting infra observations from auditing
`apps/rishi-electron/e2e/menu-{commands,library,recent}.spec.ts`. Per
plan §1, the helper `e2e/helpers/electron-app.ts` is out of scope for
filed findings, but observations gathered while reading the specs are
recorded here to feed the dedicated helper audit.

## Helper surface relied on by these specs

- `launchApp()` / `closeApp(launched)` — used by all three specs.
- `importBook(page, { fixturePath, kind, title })` — used by
  `menu-commands` and `menu-recent`.
- `openBook(page, bookId)` — used by `menu-commands`.
- `clickMenuItem(app, [path...])` — used by `menu-commands` and
  `menu-recent`.
- `getApplicationMenu(app)` / `findMenuItem(menu, [path...])` — used
  by `menu-library` and `menu-recent`.
- `PDF_FIXTURE` — shared fixture path constant.

## Infra observations to forward to the helper audit

### I1. userDataDir / DB tear-down semantics undocumented at call site
The specs assume (per plan §2.1 last bullet, §2.3 last bullet) that
`closeApp(launched)` purges the per-launch userDataDir so a bookmark
added in `menu-commands` or a book imported in `menu-recent` cannot
leak into another spec. None of the three call sites verify or
document this — they rely on the helper. If `launchApp` does not mint
a fresh userDataDir per launch, every menu spec is contaminating
every other spec's state. Recommended: helper audit should explicitly
document the per-launch isolation guarantee in a JSDoc on
`launchApp` and add an assertion in the helper that the dir is
brand-new at launch.

### I2. Focus-shaping is a recurring per-spec pattern
Both `menu-commands.spec.ts` (L17-24, again at L94-111 inside the
retry loop) and `menu-recent.spec.ts` (L17-24) duplicate the same
"get-all-windows / restore-if-minimized / show / focus / pacing
wait" sequence. The plan calls this out as "the same focus-shaping
pattern". Recommended: hoist into a helper like
`focusWindow(launched, { matchUrl?: string })` so the pattern lives
in one place and per-spec drift is impossible. This would also
naturally absorb the `bringToFront()` vs `BrowserWindow.focus()`
race noted in practices-audit P4.

### I3. `expect.poll` vs `waitForTimeout` would benefit from a helper
Several waits are sized at 200/300/400/1200/1800ms in these three
specs (see practices-audit P1). A small helper like
`pollMenuStable(app, path)` and `pollBookmarkCount(page, syncId)`
would let specs replace literal timeouts with intent-named polls and
let infra tune the polling/timeout budget centrally.

### I4. Menu rebuild trigger leaks into the test
`menu-recent.spec.ts` L38-41 reaches into
`(window as any).electron.refreshMenu()` from the test because the
spec comment notes "in production the library renderer fires this
after every successful import; here we call it directly to avoid
relying on platform-specific window focus behavior". This is a
test-only escape hatch — it works, but documenting it on the helper
(`triggerMenuRebuild(launched)`) keeps the typing burden out of
every spec.

### I5. Reviewer-1 flake-check command depends on no build step
Plan §4.4 documents a 3-run loop but assumes the main-process build
exists. There is no `pretest:e2e` hook (plan §4.1 confirms). If
B-T6's findings reach the flake-check stage, the runner must remember
to `pnpm --filter rishi-electron build` first. Recommended: have the
helper audit consider adding a `pretest:e2e` script to
`apps/rishi-electron/package.json` so flake-check loops are immune
to a stale main bundle.

## Out-of-scope confirmations (per plan §1)

- Bugs in `clickMenuItem` / `getApplicationMenu` / `findMenuItem` /
  `importBook` / `openBook` themselves are intentionally NOT filed by
  B-T6; they belong to the cross-cutting helper audit slice.
- Production `src/main/menu.ts` (menu builder) and the renderer IPC
  bridge for `menu:command` are intentionally NOT filed against from
  this slice; the plan reserves those for normal finding flow on the
  production track.
- Bookmarks DB schema / migrations are out of scope.
- TTS / Voice-chat menu items are out of scope (not exercised here).
- Per-platform Cmd/Ctrl wording variance beyond the
  `menu-library.spec.ts` regex is out of scope (though B073 narrows
  that specific regex regardless).
