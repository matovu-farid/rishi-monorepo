# Playwright Failures (baseline)

## Standard config (playwright.config.ts)

Totals: 21 failed, 87 passed, 7 skipped, 0 flaky (baseline). Plus 3 additional failures + 1 trivial pass from Phase 3.1 un-skips (see "Un-skipped specs" section below).

### Failing specs

#### e2e/azw3-parity.spec.ts
- AZW3 reader — feature parity with MOBI > View > Show TOC opens the TOC sheet — clickMenuItem(['View','Show TOC']) returned false (Expected: true, Received: false) [BROKEN] — book-window focus event does not rebuild menu in E2E (Menu.getApplicationMenu still shows library template), so the View>Show TOC item the test clicks does not exist; root cause shared with the menu cluster below. ✓ FIXED in b81e0f2f
- AZW3 reader — feature parity with MOBI > Bookmarks > Add Bookmark stores a bookmark in the DB — clickMenuItem(['Bookmarks','Add Bookmark']) returned false (Expected: true, Received: false) [BROKEN] — same per-window menu wiring regression: Bookmarks top-level is missing from the menu the test sees. ✓ FIXED in b81e0f2f

#### e2e/menu-book-epub.spec.ts
- focused EPUB book window menu hides PDF-only items — findMenuItem(menu, ['View','Show TOC']) is undefined (book-window menu is library menu) [BROKEN] — per-window menu context exists (windowContexts pre-seeded with kind:'book' in src/main/index.ts:385) but `app.on('browser-window-focus')` doesn't fire / setContext doesn't rebuild for the book window before the test reads the menu. ✓ FIXED in b81e0f2f

#### e2e/menu-book-pdf.spec.ts
- focused PDF book window menu has Bookmarks, Reader, Show Thumbnails, Dual Page — menu labels were ["Rishi","File","Edit","View","Window","Help"] (no Bookmarks/Reader) [BROKEN] — same root cause as menu-book-epub: focus handler never installs the book-context menu in the test harness. ✓ FIXED in b81e0f2f

#### e2e/menu-bookmarks-submenu.spec.ts
- Bookmarks > recent submenu reflects added bookmarks — findMenuItem(before, ['Bookmarks']) is undefined (Bookmarks top-level missing from book-window menu) [BROKEN] — Bookmarks top-level is only added when MenuContext.kind === 'book'; the menu in effect is the library default — same wiring bug. ✓ FIXED in b81e0f2f

#### e2e/menu-commands.spec.ts
- View > Switch to Dark Mode toggles theme in renderer — themeAfter still "light" (menu click did not toggle theme class) [BROKEN] — Menu.getApplicationMenu().click() dispatches to the focused webContents; if the wrong window is focused, the renderer that toggles theme never receives 'menu:command'. Shared with the menu cluster. ✓ FIXED in b81e0f2f
- Bookmarks > Add Bookmark adds a row in the DB when a PDF is open — clickMenuItem(['Bookmarks','Add Bookmark']) returned false [BROKEN] — Bookmarks item missing from the active menu for the same per-window-focus reason. ✓ FIXED in b81e0f2f

#### e2e/menu-recent.spec.ts
- File > Open Recent lists imported books and opens them — windows().length stayed at 1 after clicking Recent item (Expected: > 1, Received: 1) [BROKEN] — the 'File > Open Recent > <book>' click reaches main but `getWindowManager().openBook(bookId)` never produces a second BrowserWindow under the test environment; likely the same focus/menu-context issue causing the wrong handler to fire. ✓ FIXED in b81e0f2f

#### e2e/mobi.spec.ts
- MOBI reader > non-existent book id does not crash — getByText('Book not found') never visible within 15s (error-path UI not mounted) [STALE] — test sets `window.location.hash = '#/books/99999'` on the library window, but in Phase 3 the library window's renderer no longer hosts the book route (book routes only mount in book BrowserWindows created by openBook); the error-path render at books.$id.lazy.tsx:69 simply never runs in the library window. ✓ FIXED in 8fb58fa9

#### e2e/navigation-history-pdf.spec.ts
- Navigation history — PDF > TOC jump → pill appears → pop returns to original page — restoredPage was 4, expected <= initialPage+1 (2) [BROKEN] — pdfStore page-restore overshoots after pop; the persisted page index is not faithfully restored (related cluster includes pdf-reader.spec.ts and the second navigation-history-pdf failure). ✓ FIXED in 7ad4c905
- Navigation history — PDF > engagement tap → flip away → pop returns to engaged page — restoredPage was 8, expected <= engagedPage+1 (3) [BROKEN] — same pdfStore restore overshoot, larger delta because the engaged target is further from the current position. ✓ FIXED in 7ad4c905

#### e2e/navigation-history-epub.spec.ts
- Navigation history — EPUB > simulated internal link jump → pill → pop returns to original CFI — [data-testid="nav-history-back-label"] not visible within 10s (pill never appeared) [BROKEN] — nav-history pill is no longer rendered for EPUB internal-link jumps; production code path that pushes onto the nav stack and shows the pill regressed during Phase 3 player/window split.

#### e2e/pdf-footer-detection.spec.ts
- paragraph indices stay stable when the heuristic engages (gaps preserved) — bookPage.waitForFunction (waiting for pdfStore page reach) timed out at 30s [BROKEN] — virtualizer.scrollToIndex fires but currentViewParagraphs never gains entries with the target page's encoded index (page * 10000 + idx) within 30s; pdfStore paragraph publication regressed after the Phase 3 player-actor restructure (#252). ✓ FIXED in 66a042f8

#### e2e/pdf-reader.spec.ts
- PDF reader > keyboard navigation advances and restores the persisted page index — ArrowRight did not advance persisted page (poll stayed at 1, expected > 1) [BROKEN] — ArrowRight no longer advances the persisted pdfStore page index; same family as the navigation-history-pdf overshoots — pdfStore page-tracking regression after #252/#253. ✓ FIXED in a2194f23

#### e2e/pdf-scroll-up-jitter.spec.ts
- scrolling up across a page boundary does not jitter — remountedAbove was false (page above prior mount window did not remount during scroll-up) [BROKEN] — virtualizer's overscan/remount-above behavior is no longer triggered on upward scroll; production virtualizer wiring regressed (paired with the pdf-footer-detection paragraph publication bug — both are pdfStore/virtualizer issues post-#252). ✓ FIXED in 67e01b0b

#### e2e/search.spec.ts
- Search > searchBookText IPC accepts a query — result array length was 0 (Expected: > 0) [STALE] — the test was added by b2910cc5 asserting FTS returns hits, but the e2e `importBook` helper (e2e/helpers/electron-app.ts:100) inserts the book row directly and bypasses the chunk-data/FTS indexing pipeline that real imports run. The chunk_data_fts virtual table is empty for this book, so the FTS MATCH legitimately returns 0 rows; the contract the test asserts requires either using importBookViaOpenFile or seeding chunk_data. ✓ FIXED in 68ececf8

#### e2e/tts-page-navigation.spec.ts
- clicking Next during playback pauses the OLD page audio immediately — playingBefore.paused was true (audio was not playing when Next was clicked; timing/setup issue) [FLAKE] — passes in isolation (3/3) but flakes in suite due to T2 cascade. The audioActor stale-blob fix (4be58ee3) cleans the worst case but the 100 ms silent-mock WAV is too short for the post-#252 fast-`playing`-entry path to leave a stable observation window; reclassify as FLAKE. ✓ FIXED in 77c78f6b
- audio.play() is NOT called for stale blob when state moves on during loadAndPlayAudio — bleed detected: audio.play() fired for off-page CFI epubcfi(/6/4!/4/10/2,/1:0,/1:33) [BROKEN] — stale-blob guard missing: loadAndPlayAudio fires audio.play() for an OLD CFI after the player has moved on. The guard contract is in the test; production lost it during #252. ✓ FIXED in 4be58ee3
- Stop+Play immediately after Next does NOT replay the old page — priority-1 TTS request issued for OLD page CFI after Next+Stop+Play [FLAKE] — isolation runs alternate pass/fail (2/5 → 1/3 across variants); the 'Next click + immediate STOP+PLAY' sequence races the page-curl commit window. Pre-existing flake, not introduced by #252; the deterministic part of the contract is covered by 'audio.play() is NOT called for stale blob' which is now green. ✓ FIXED in 370fd666
- T2: Stuck-loop reproducer - PLAY after pageNavigating timeout must not cause unwanted nav (BUG) — STUCK LOOP: clicking Play after pageNavigating timeout caused unwanted page advance [BROKEN — test design] — fails 5/5 in isolation. Root cause is in the TEST setup, not production: the first PLAY's natural auto-advance moves the rendition off page 1 within the 30-200ms window between `waitForPlayerState('playing')` and the forged PAGE_NAVIGATING send (the silent mock TTS plays a real 100ms WAV which fires AUDIO_ENDED and auto-advances through paragraphs → NAVIGATE_NEXT → rendition.next() in <200ms). pageBefore is captured BEFORE PLAY but pageAfter is captured AFTER the second PLAY, so the rendition's earlier auto-advance is mis-attributed to the second PLAY. The production `republishingParagraphs` fix for the documented bug class is in place; the test would need to either record pageBefore AFTER first PLAY settles, or use a TTS mock whose audio never reaches `canplaythrough`. BLOCKED on test redesign. ✓ FIXED in 657e226c
- player PREV at first paragraph lands on last paragraph of previous page — PREV landed on FIRST paragraph of previous page, not LAST (off-by-one) [FLAKE] — isolation runs alternate pass/fail (1/3 fail). The PREV path's relocated-burst race (epubjs emits multiple `relocated`s during a curl; the first can carry the old CFI which the view actor treats as `sameView` and emits NAV_NO_PROGRESS → stopped before the real destination relocated arrives) intermittently lands the player on paragraph 0 instead of last. Pre-existing race, not introduced by #252; covered structurally by view-actor settle guard. ✓ FIXED in 4b50fa12

## Sharing config (playwright.sharing.config.ts)

Totals: 1 failed, 9 passed, 0 skipped, 0 flaky

### Failing specs

#### e2e/sharing.approval.spec.ts
- requiresApproval: viewer queued → host approves → both live — hostSnap.context.pendingJoiners.length was 0 (host never observed the viewer's join request, Expected: > 0) [FLAKE] — test reads host snapshot immediately after viewer reaches `awaitingApproval`, with no wait for the host's WS broadcast to arrive. The worker's rehydratePendingFromHibernation fired correctly (workers/sharing-worker/src/SessionRoom.ts:327) but the host has not yet processed the `pendingJoiners` broadcast event by the time readSessionSnapshot runs — a classic race the spec does not await out. ✓ FIXED in 83d443ef

## Un-skipped specs (Phase 3.1)

After un-skipping the 4 hard-skipped specs:
- e2e/pdf-warm-restore.spec.ts:33 — `reopening a PDF hits the warm-restore cache and renders pages` — canvas locator never visible (test calls gotoLibrary then expects same-window remount) [STALE] — Phase 3 window split removed the in-window navigation path; the test exercises a code path that no longer exists (`gotoLibrary` then reopen in the same renderer). The skip comment in the file already states this; the test body must be rewritten for the per-window lifecycle. ✓ FIXED in c90d8ecf
- e2e/epub-cache-no-flash.spec.ts:28 — `warm-restore reopen does not flash the inner loading view` — iframe locator never visible after gotoLibrary [STALE] — same as above: in-window reopen path replaced by per-book BrowserWindow; closing the book window destroys its renderer instead. ✓ FIXED in 348547ee
- e2e/epub-warm-restore.spec.ts:69 — `first open populates the cache, second open hits it` — iframe locator never visible after first open inside the library window [STALE] — same per-window split: the cross-navigation warm-restore the test exercises no longer exists. ✓ FIXED in 0e5d7e7b
- e2e/pdf-footer-detection.spec.ts:103 — `masked items live in the bottom band` — PASSED (test body is a stub TODO so trivially succeeds; not a true assertion yet).

## Notes

- Phase 0 left `node_modules/better-sqlite3` built for Node ABI 127 (Node 22). The first standard run failed all 50 specs at `firstWindow()` because Electron (ABI 140) refused to load the .node file. Reran `scripts/ensure-native-abi.cjs` and the standard suite went from 50F to 21F.
- Wrangler globalSetup for the sharing suite came up cleanly (`http://localhost:8788` ready) — no infra failure.
- 6 of 21 standard failures cluster around the Electron application menu: book-window menus expose only the default ["Rishi","File","Edit","View","Window","Help"] labels and never gain Bookmarks/Reader/Show TOC. This points to `setApplicationMenu`/per-window menu wiring rather than 6 independent bugs.
- 5 of 21 standard failures are in `tts-page-navigation.spec.ts` and all describe the same family of bugs (stale blob bleeds, replaying old page after Next, PREV landing on first instead of last paragraph). These look like real TTS/page-navigation state bugs, not flakes.
- 3 of 21 are PDF position/history (`navigation-history-pdf.spec.ts` x2, `pdf-reader.spec.ts` x1): persisted page index isn't being restored or the pop-to-page is overshooting by 2-5 pages.
- No retries were configured (`playwright.config.ts` has no `retries`), so every "failed" entry is a single deterministic miss — none of the 21 are flake-on-retry.
- `test-results/` contains traces/screenshots for the 22 total failures if any need deeper inspection (`pnpm exec playwright show-trace <path>`).
