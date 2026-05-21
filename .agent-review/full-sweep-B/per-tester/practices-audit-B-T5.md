# Practices Audit — Tester B-T5 (menu-book group)

Scope: `menu-book-epub.spec.ts`, `menu-book-pdf.spec.ts`,
`menu-bookmarks-submenu.spec.ts`.

## 1. Hard-coded `waitForTimeout` for async menu rebuild

All three specs use raw `waitForTimeout` to bridge async work:

| Location                                                | Wait    | Bridging                            |
|---------------------------------------------------------|---------|-------------------------------------|
| `menu-book-epub.spec.ts:21`                             | 2500ms  | book open + initial render          |
| `menu-book-epub.spec.ts:27`                             | 500ms   | renderer settle pre-evaluate        |
| `menu-book-epub.spec.ts:41`                             | 800ms   | focus → menu rebuild + re-apply     |
| `menu-book-pdf.spec.ts:21,26,40`                        | same    | same                                |
| `menu-bookmarks-submenu.spec.ts:40,52,61`               | 2500/600/1500ms | book open, focus, publish    |

Recommendation: replace with `expect.poll(...)` against
`getApplicationMenu(launched.app)` returning the expected shape. The
`waitForTimeout(500)` "settle" pre-evaluate is uniquely defensible (it
guards against a known electron-playwright foot-gun where
`electronApplication.evaluate` races with renderer navigation), but the
800/1500ms post-focus waits are not — they measure menu state with no
explicit synchronization on the rebuild signal. Tracked separately in
`test-infra-B-T5.md`.

## 2. Swallowed evaluate failures

`menu-book-epub.spec.ts:40` and `menu-book-pdf.spec.ts:39`:
```
.catch(() => {})
```
Filed as B060. The pattern is repeated across both specs; cross-spec
practice violation, not just a single-test issue.

## 3. Duplicated focus preamble (DRY)

All three specs hand-roll the same
`BrowserWindow.getAllWindows().find(w => w.webContents.getURL().includes(url))`
focus dance. The URL-substring match (`/books/${id}`) is load-bearing —
if the router changes the URL shape, all three specs fail in the same
opaque way. Extract to `e2e/helpers/electron-app.ts` as
`focusBookWindow(app, bookId)` and add a smoke test for the helper.

## 4. Negative assertions without parent guards

`menu-book-epub.spec.ts:45-46` checks leaf items under `View` are
undefined without first asserting `View` is defined. The negative
assertion is satisfied vacuously when the parent is missing. Filed as
B056. Same shape is implicit in `menu-book-pdf.spec.ts` (which lacks the
parallel Show-TOC-absent check; see B057).

## 5. Assertion strength — too-weak content checks

`menu-bookmarks-submenu.spec.ts:67-69` asserts merely "some label exists
that isn't a known static label". Filed as B059. General principle: when
asserting menu *content*, pin the format with a regex or include-check;
do not assert "anything not in this denylist".

## 6. Single-snapshot menu reads (no retry)

`menu-book-pdf.spec.ts:42` and `menu-book-epub.spec.ts:43` take exactly
one `getApplicationMenu(launched.app)` snapshot after a raw wait. No
retry, no poll. If the menu rebuild straddles the 800ms wait, the
assertion fails with no second chance. Use `expect.poll` to wrap the
snapshot + leaf assertion together.

## 7. Production-path bypass

`menu-bookmarks-submenu.spec.ts:25-37` bypasses the cloud-sync engine by
injecting `syncId` via `saveBook`. Documented in code with a comment,
but no companion test exists that exercises the un-bypassed path. Filed
under parity-gaps §3 rather than here, but listed for cross-reference.

## 8. No teardown of created bookmarks

`menu-bookmarks-submenu.spec.ts` adds a bookmark and never asserts the
row count or cleans it up. Per-test launch with a tmp userDataDir
implicitly cleans, but if that ever regresses, bookmark rows would
accumulate. Note only.

## 9. Sentinel-event signalling missing in production

The menu publish path in `src/main/ipc/menu.ts` does not (as far as
these specs use it) expose an awaitable "menu-applied" signal that
tests could subscribe to. This is a production-test seam improvement —
the right place to fix the timing issues catalogued in §1 is on the
production side, not by tuning timeouts in the spec. Tracked in
`test-infra-B-T5.md`.
