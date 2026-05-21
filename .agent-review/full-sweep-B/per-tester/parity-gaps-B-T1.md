# Phase B parity gaps — Tester B-T1

Scope: 4 AZW3 e2e specs (`azw3-column-alignment`, `azw3-open`, `azw3-parity`, `azw3-render-content`).

- **Import dispatch routing untested for AZW3 inside this file set.** All 4 specs call `importBook(launched.page, { kind: 'azw3', ... })` which (per plan-azw3 §2.1 / pilot 2.4) hard-codes `kind` and bypasses the real format-detection dispatch. The only spec that exercises the real routing path is `azw3-real-import-routing.spec.ts` (out of this tester's scope). Gap: if these 4 are run alone, no signal exists that the .azw3 → AZW3-reader dispatch wiring is intact.
- **No `goToPage(N)` / jump-to-percent test for AZW3.** EPUB has location/percent jump coverage; AZW3 only exercises Next/Prev one step at a time (column-alignment L88-108, parity L38-53, render-content L164-170). A regression where direct chapter jumps stop emitting `pagechanged` would not be caught.
- **No TOC entry click → navigate parity test.** `azw3-parity.spec.ts:59-86` opens the TOC sheet and asserts it is visible, but never clicks an entry and never asserts the counter moves. MOBI has equivalent coverage (per plan); AZW3 stops one step short.
- **No bookmark removal / list-update parity test.** `azw3-parity.spec.ts:88-174` covers Add Bookmark only. Remove Bookmark via menu, and refresh of the in-app sidebar bookmark list after add/remove, are not exercised for AZW3.
- **No "second AZW3 window in parallel" test.** The bookmark-syncId-on-mount race (see B001) is amplified when two AZW3 windows are open concurrently and a syncId arrives mid-flight; no spec covers this multi-window case.
- **No `azw3-real-import-routing` coverage in this set** (handled elsewhere) — noted only so the cross-file reviewer doesn't expect duplicate signal here.
