# Playwright Failures (baseline)

## Standard config (playwright.config.ts)

Totals: 21 failed, 87 passed, 7 skipped, 0 flaky

### Failing specs

#### e2e/azw3-parity.spec.ts
- AZW3 reader — feature parity with MOBI > View > Show TOC opens the TOC sheet — clickMenuItem(['View','Show TOC']) returned false (Expected: true, Received: false)
- AZW3 reader — feature parity with MOBI > Bookmarks > Add Bookmark stores a bookmark in the DB — clickMenuItem(['Bookmarks','Add Bookmark']) returned false (Expected: true, Received: false)

#### e2e/menu-book-epub.spec.ts
- focused EPUB book window menu hides PDF-only items — findMenuItem(menu, ['View','Show TOC']) is undefined (book-window menu is library menu)

#### e2e/menu-book-pdf.spec.ts
- focused PDF book window menu has Bookmarks, Reader, Show Thumbnails, Dual Page — menu labels were ["Rishi","File","Edit","View","Window","Help"] (no Bookmarks/Reader)

#### e2e/menu-bookmarks-submenu.spec.ts
- Bookmarks > recent submenu reflects added bookmarks — findMenuItem(before, ['Bookmarks']) is undefined (Bookmarks top-level missing from book-window menu)

#### e2e/menu-commands.spec.ts
- View > Switch to Dark Mode toggles theme in renderer — themeAfter still "light" (menu click did not toggle theme class)
- Bookmarks > Add Bookmark adds a row in the DB when a PDF is open — clickMenuItem(['Bookmarks','Add Bookmark']) returned false

#### e2e/menu-recent.spec.ts
- File > Open Recent lists imported books and opens them — windows().length stayed at 1 after clicking Recent item (Expected: > 1, Received: 1)

#### e2e/mobi.spec.ts
- MOBI reader > non-existent book id does not crash — getByText('Book not found') never visible within 15s (error-path UI not mounted)

#### e2e/navigation-history-pdf.spec.ts
- Navigation history — PDF > TOC jump → pill appears → pop returns to original page — restoredPage was 4, expected <= initialPage+1 (2)
- Navigation history — PDF > engagement tap → flip away → pop returns to engaged page — restoredPage was 8, expected <= engagedPage+1 (3)

#### e2e/navigation-history-epub.spec.ts
- Navigation history — EPUB > simulated internal link jump → pill → pop returns to original CFI — [data-testid="nav-history-back-label"] not visible within 10s (pill never appeared)

#### e2e/pdf-footer-detection.spec.ts
- paragraph indices stay stable when the heuristic engages (gaps preserved) — bookPage.waitForFunction (waiting for pdfStore page reach) timed out at 30s

#### e2e/pdf-reader.spec.ts
- PDF reader > keyboard navigation advances and restores the persisted page index — ArrowRight did not advance persisted page (poll stayed at 1, expected > 1)

#### e2e/pdf-scroll-up-jitter.spec.ts
- scrolling up across a page boundary does not jitter — remountedAbove was false (page above prior mount window did not remount during scroll-up)

#### e2e/search.spec.ts
- Search > searchBookText IPC accepts a query — result array length was 0 (Expected: > 0)

#### e2e/tts-page-navigation.spec.ts
- clicking Next during playback pauses the OLD page audio immediately — playingBefore.paused was true (audio was not playing when Next was clicked; timing/setup issue)
- audio.play() is NOT called for stale blob when state moves on during loadAndPlayAudio — bleed detected: audio.play() fired for off-page CFI epubcfi(/6/4!/4/10/2,/1:0,/1:33)
- Stop+Play immediately after Next does NOT replay the old page — priority-1 TTS request issued for OLD page CFI after Next+Stop+Play
- T2: Stuck-loop reproducer - PLAY after pageNavigating timeout must not cause unwanted nav (BUG) — STUCK LOOP: clicking Play after pageNavigating timeout caused unwanted page advance
- player PREV at first paragraph lands on last paragraph of previous page — PREV landed on FIRST paragraph of previous page, not LAST (off-by-one)

## Sharing config (playwright.sharing.config.ts)

Totals: 1 failed, 9 passed, 0 skipped, 0 flaky

### Failing specs

#### e2e/sharing.approval.spec.ts
- requiresApproval: viewer queued → host approves → both live — hostSnap.context.pendingJoiners.length was 0 (host never observed the viewer's join request, Expected: > 0)

## Notes

- Phase 0 left `node_modules/better-sqlite3` built for Node ABI 127 (Node 22). The first standard run failed all 50 specs at `firstWindow()` because Electron (ABI 140) refused to load the .node file. Reran `scripts/ensure-native-abi.cjs` and the standard suite went from 50F to 21F.
- Wrangler globalSetup for the sharing suite came up cleanly (`http://localhost:8788` ready) — no infra failure.
- 6 of 21 standard failures cluster around the Electron application menu: book-window menus expose only the default ["Rishi","File","Edit","View","Window","Help"] labels and never gain Bookmarks/Reader/Show TOC. This points to `setApplicationMenu`/per-window menu wiring rather than 6 independent bugs.
- 5 of 21 standard failures are in `tts-page-navigation.spec.ts` and all describe the same family of bugs (stale blob bleeds, replaying old page after Next, PREV landing on first instead of last paragraph). These look like real TTS/page-navigation state bugs, not flakes.
- 3 of 21 are PDF position/history (`navigation-history-pdf.spec.ts` x2, `pdf-reader.spec.ts` x1): persisted page index isn't being restored or the pop-to-page is overshooting by 2-5 pages.
- No retries were configured (`playwright.config.ts` has no `retries`), so every "failed" entry is a single deterministic miss — none of the 21 are flake-on-retry.
- `test-results/` contains traces/screenshots for the 22 total failures if any need deeper inspection (`pnpm exec playwright show-trace <path>`).
