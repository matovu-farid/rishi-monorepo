# Parity Gaps — Tester B-T5 (menu-book group)

Scope: `menu-book-epub.spec.ts`, `menu-book-pdf.spec.ts`,
`menu-bookmarks-submenu.spec.ts`.

## 1. Format enablement parity (EPUB vs PDF)

| Menu item       | PDF spec asserts | EPUB spec asserts | Gap                                                |
|-----------------|------------------|-------------------|----------------------------------------------------|
| Show TOC        | (none)           | present           | **PDF must assert absent** — see B057              |
| Show Thumbnails | present          | absent            | EPUB negative is vacuous if View missing — see B056|
| Dual Page       | present          | absent            | Same as Show Thumbnails — covered by B056          |
| Bookmarks (top) | present          | present           | OK                                                 |
| Reader (top)    | present          | present           | OK                                                 |

Production gating: `src/main/menu/menuBuilder.ts:60-99` keys on `bookKind`.
The unit test `src/main/menu/menuBuilder.test.ts:102-118` covers both
directions at the template-builder layer; the e2e specs cover only one
direction each at the install+publish layer. Filing as parity gap, not
duplicate, because the install/publish layer is the actual integration
seam.

## 2. Trigger-path parity (menu click vs accelerator vs IPC)

- `menu-bookmarks-submenu.spec.ts:58` exercises only the menu-click path
  for `Add Bookmark`. The accelerator `CmdOrCtrl+D` is registered
  (`src/main/menu/accelerators.ts:9`) and dispatched via menu role, but
  no e2e test fires the accelerator. If the accelerator wiring regresses
  (e.g. accelerator string typo, conflict with another menu item, or the
  role is bound to a no-op handler), the spec passes.
- Direct IPC (`window.electron.addBookmark` or equivalent) is not
  exercised from these specs either. The three paths can diverge.

Recommendation: add a sibling spec
`e2e/menu-bookmarks-accelerator.spec.ts` that triggers `CmdOrCtrl+D` and
asserts the same submenu mutation. Reuse helper from B060 once written.

## 3. Bookmarks injection bypass (production-path parity)

`menu-bookmarks-submenu.spec.ts:25-37` injects `syncId` directly via the
`saveBook` IPC to short-circuit the cloud-sync engine. The natural
production path (`addBookmark` → sync engine assigns `sync_id`) is
therefore untested at e2e. If the sync engine stops assigning `sync_id`
on bookmark creation, the test passes but real users see the menu
publish short-circuit. Parity gap with the production happy path.

Recommendation: separate spec that runs with the in-process sync engine
enabled (opt-in via env flag) and asserts the same menu-publish outcome
without the renderer-side injection.

## 4. Menu-item enabled/disabled state

None of the three specs assert `enabled: true | false`. `Add Bookmark`
is presumably disabled when no book is focused; `Show TOC` may be
disabled before the EPUB finishes parsing. The presence/absence
assertions today say nothing about whether the user can actually
*click* the item. Parity gap with the production UX contract.

## 5. View submenu presence

Neither EPUB nor PDF spec asserts `findMenuItem(menu, ['View'])` is
defined before drilling into its children. If View is omitted entirely,
all leaf-negative assertions pass vacuously (see B056). Symmetric
addition needed on both specs.

## 6. Cross-window menu state

Neither spec exercises the *transition* — focus the book window
(expect format-specific items), focus another window (expect them gone),
focus back (expect them again). The menu-rebuild-on-focus contract is
only sampled once per spec, in the steady-state direction.
