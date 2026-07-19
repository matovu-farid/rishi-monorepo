# Reader (PDF + EPUB)

[Back to contributor README](../README.md)

## What it does

The Reader opens PDF files via Apple's PDFKit framework and EPUB files
via the Readium 3.9 library (an open-source EPUB engine). Both formats
share a chrome (toolbar, tap-to-toggle UI, themes, table of contents).
The user can page through, highlight text in four colors, attach a note
to a highlight, jump to a chapter, switch theme (Match Device, light,
sepia, dark), and on EPUB tune typography. Match Device is the default;
it resolves to light or dark from the system appearance at read time.
Settings reader defaults seed theme on open for any book without a
per-book theme key yet (not font family).

## The user flow

- Tap a book on the Library.
- A loading overlay shows during the first parse; later opens are
  nearly instant thanks to on-disk caching.
- The book opens at the last-read position (saved locally and synced).
- Tap the middle of the page to show/hide the chrome; tap the edges to
  page.
- Long-press selected text to highlight, color, or annotate.
- Open the TOC sheet to jump to a chapter; open the theme picker.

## Where it lives

| Role | File |
| --- | --- |
| Unified reader screen (EPUB + PDF routes) | `Packages/RishiReader/Sources/RishiReader/UI/ReaderScreen.swift` |
| EPUB view model | `Packages/RishiReader/Sources/RishiReader/EPUB/ReaderViewModel.swift` |
| PDF view model | `Packages/RishiReader/Sources/RishiReader/PDF/PDFReaderViewModel.swift` |
| Legacy PDF-only screen (compile parity, not in nav) | `Packages/RishiReader/Sources/RishiReader/UI/PDFReaderScreen.swift` |
| Shared loading state | `Packages/RishiReader/Sources/RishiReader/ReaderLoadingState.swift` |
| EPUB unpack cache | `Packages/RishiReader/Sources/RishiReader/EPUB/EPUBUnpackedCache.swift` |
| PDF thumbnail cache | `Packages/RishiReader/Sources/RishiReader/PDF/PDFThumbnailCache.swift` |
| Tap-to-page resolver | `Packages/RishiReader/Sources/RishiReader/UI/ReaderTapRegionResolver.swift` |
| Import-time prewarming | `Packages/RishiReader/Sources/RishiReader/Prewarm/BookPrewarmer.swift` |
| Persistence | `PositionStore`, `HighlightStore` from `RishiDB` |

## What it depends on

- `RishiCore` — `Book`, `Position`, `Highlight`, `HighlightColor`.
- `RishiDB` — stores for positions and highlights.
- `RishiLibrary` — `BookFileStorage` for resolving file URLs on disk.
- `RishiUIKit` — colors, typography, highlight color swatches.
- `Readium 3.9` (EPUB only) and `PDFKit` (PDF only). Engine swaps are
  forbidden by the durable constraints in `apps/apple/CLAUDE.md`.

## Why it's built this way

- The cold-open parse runs on a `Task.detached(priority: .userInitiated)`
  because the Readium ZIP unpack and the PDFKit document load would
  otherwise stall the main thread. The screen reflects the in-flight
  parse via `ReaderLoadingState` (a `Sendable` enum) so the loading
  overlay and the parse are decoupled.
- `EPUBUnpackedCache` lives under `~/Library/Caches/EPUBUnpacked/` and
  survives app restarts. PDFs already cached for free via PDFKit; the
  EPUB asymmetry was the Phase 21 fix.
- Tap-to-page lives in a pure value-typed resolver, wired via a SwiftUI
  `.simultaneousGesture` overlay on the Readium or PDFKit view. The
  native `TabView(.page)` idiom does not compose with PDFKit's scroll
  view or Readium's WKWebView — see `docs/SWIFTUI-NATIVE-CHOICES.md`.
- Highlight locator codecs are versioned (`pdf-v1`, `epub-v1`). Schema
  changes require a bump and a decoder fallback so synced highlights
  keep working.
- The reader sits in a `NavigationStack`, not a `.fullScreenCover`. That
  was the Phase 18 fix for the "reader-trap" bug where the user lost
  the system back gesture.

## Gotchas

- Highlight locators are PDF-user-space coordinates for PDF and CFI
  strings (a Readium-specific position format) for EPUB. They are not
  interchangeable.
- `BookPrewarmer` kicks off a parse at import time. If you change
  import flow, make sure the prewarm hook still fires.

---

**Next:** [sync.md](sync.md) — how local reader state (positions, highlights, conversations) travels to the worker and back.
