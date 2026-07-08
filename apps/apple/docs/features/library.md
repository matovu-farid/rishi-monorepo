# Library

[Back to contributor README](../README.md)

## What it does

The Library is the home screen. It shows the user's books as a grid of
covers, with a "Reading Now" shelf at the top for partially-read books.
The user can search, tap to open a book, long-press for a context menu
(delete or continue reading), and import new books from the system
Files app or by sharing a file into Rishi.

## The user flow

- Open the app. The Library tab is the first thing visible.
- See books as cover thumbnails; in-progress books appear in the
  "Reading Now" shelf at the top.
- Type in the search field to filter by title or author.
- Tap a book to open the reader.
- Long-press a book for "Continue Reading" and "Delete".
- Tap import (or share a file from another app) to add a new book. The
  format is detected from the file extension.

## Where it lives

| Role | File |
| --- | --- |
| Entry point view | `Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryRootView.swift` |
| View model | `Packages/RishiLibrary/Sources/RishiLibrary/ViewModel/LibraryViewModel.swift` |
| Grid | `Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryGrid.swift` |
| Reading Now shelf | `Packages/RishiLibrary/Sources/RishiLibrary/Views/ReadingNowShelf.swift` |
| File import | `Packages/RishiLibrary/Sources/RishiLibrary/Import/` |
| On-disk book file storage | `Packages/RishiLibrary/Sources/RishiLibrary/Storage/` |
| Persistence | `BookStore` and `PositionStore` from `RishiDB` |

## What it depends on

- `RishiCore` — `Book`, `Position`, `BookID` types.
- `RishiDB` — stores for books and positions.
- `RishiUIKit` — shared color, typography, spacing tokens.
- `RishiLogging` — for `os.Logger` and Sentry breadcrumbs.

It does not depend on `RishiReader` or `RishiSync`. Those packages talk
to the same stores; the Library never calls them directly.

## Why it's built this way

- The view model is `@Observable` and lives on the main actor, but
  expensive work (fetching books, resolving cover URLs) goes through
  async stores so it does not stall the UI.
- Cover URLs are pre-resolved into a map on the view model before the
  grid renders. This was a Phase 21 fix — covers used to pop in a second
  after the placeholder because resolution ran per-cell after layout.
- Search uses `String.localizedStandardContains`, the same primitive
  Finder and Spotlight use. Locale- and diacritic-aware matching is
  free.
- Search is debounced 150 ms. The empty-query case skips the debounce
  so clearing the field never flashes "no results".

## Gotchas

- `BookFileStorage` is `final class @unchecked Sendable`, not an actor.
  Serialization comes from the file system. Do not wrap it in an actor.
- Sample books are bundled in the package's resources and installed on
  first launch by `SampleBookInstaller`. If they do not appear, check
  that `Bundle.module` resolves for the target.

---

**Next:** [auth.md](auth.md) — sign-in. Required reading before any cloud-touching feature (sync, chat, voice, billing).
