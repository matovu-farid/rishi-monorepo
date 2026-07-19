# Reader Match Device theme — Design

**Date:** 2026-07-19  
**Status:** Approved direction (Apple Books–style)  
**Scope:** Apple app reader appearance consistency (`apps/apple`)

## Problem

The Library (and other shell UI) follows the **system** appearance via adaptive `RishiColor` tokens. Readers use a separate per-book `ReaderTheme` (`light` / `sepia` / `dark`) that defaults to **`light`** and forces SwiftUI chrome with `.preferredColorScheme`.

Result: on a dark system, Library → EPUB is a hard light flash. Settings “Reader Defaults” claim to apply to new books but are never read on open.

## Goal

Match Apple Books / Kindle / Libby norms:

1. Shell keeps following system (no new app-wide Light/Dark/System control).
2. Reader default is **Match Device** so opening a book does not fight system appearance.
3. User can still override per book (and via Settings defaults for first open) with Light / Sepia / Dark.
4. Settings reader default is actually applied on first open of a book.

## Non-goals

- App-level appearance override for Library / Settings / Chat.
- Recoloring PDF page bitmaps (chrome/margins only; same limitation as Apple Books).
- Syncing reader theme to non-Apple clients in this change.
- Fixing font-family default seeding (same docs gap exists; track separately if needed).
- Wiring unused `PDFReaderScreen` into navigation (today both EPUB and PDF routes use `ReaderScreen`).

## Model

### `ReaderTheme` cases

| Case | Persisted rawValue | Meaning |
|------|--------------------|---------|
| `matchDevice` | `"matchDevice"` | Follow system light/dark for page + chrome |
| `light` | `"light"` | Force light page + chrome |
| `sepia` | `"sepia"` | Sepia page; force light chrome |
| `dark` | `"dark"` | Force dark page + chrome |

- **`ReaderTheme.default`** becomes **`.matchDevice`** (was `.light`).
- `CaseIterable` order: `matchDevice`, `light`, `sepia`, `dark`.
- Existing per-book raw values (`light` / `sepia` / `dark`) keep working; no migration rewrite.
- Books with **no** persisted theme key behave as Match Device on first paint (via sync peek → `AppReaderDefaults` / `.default`), then the app default is **seeded** into the per-book store on open.
- **Upgrade note:** Books opened before this change may have no per-book key even if they were read under the old implicit-light fallback. First open after upgrade seeds the current app default (Match Device unless Settings was changed).

### Resolution (render-time)

`matchDevice` is a preference, not a Readium theme. At apply time:

```text
resolved(isDark:) → light | sepia | dark   // never matchDevice
  matchDevice + dark system  → dark
  matchDevice + light system → light
  light | sepia | dark       → self
```

- EPUB: pass **resolved** theme into `EPUBPreferencesBridge` / backgrounds.
- Live reader container: pass **resolved** theme into `ReaderView` UIKit margins (`pageTheme`). Do not leave margins on raw `viewModel.theme` — `matchDevice` would paint light and would not refresh on system appearance changes.
- PDF (same `ReaderScreen` path): chrome + `ReaderView` margins follow resolved theme; Readium `applyPreferences` is EPUB-only; page bitmaps may stay light.
- Chrome: `.preferredColorScheme`:
  - `matchDevice` → `nil` (follow system)
  - `dark` → `.dark`
  - `light` / `sepia` → `.light`
- While a book is open on `matchDevice`, observe `@Environment(\.colorScheme)`: re-run `applyPreferences()` (EPUB) and rely on `pageTheme: resolvedTheme` changing so `ReaderView.updateUIViewController` refreshes margins.

### Settings vs per-book

| Layer | Key | Behavior |
|-------|-----|----------|
| App default | `reader.defaults.theme` | Fallback when a book has never had a theme written. Missing key → `matchDevice`. |
| Per-book | `reader.settings.<uuid>.theme` | Explicit override from in-reader picker. |

**First open / first paint:**

1. Sync once in `ReaderDestination.init`: `peekPersistedTheme` if present, else `AppReaderDefaults.theme` → set `viewModel.theme` before `@State` capture (no flash; survives SwiftUI body refreshes).
2. Async `.task` on `ReaderScreen`: if per-book key missing → **seed only** (`setTheme`); do not re-assign `viewModel.theme`. Always load typography as today.

Changing Settings later does not rewrite books already seeded; it only affects future first opens. In-reader picker always writes per-book.

### UI labels

- Pickers (Settings, EPUB/PDF theme sheets, Mac menu): **Match Device**, Light, Sepia, Dark.
- Match Device swatch: adaptive / split treatment (not a third fixed page color).

## Architecture

```text
AppReaderDefaults.theme ──► ReaderScreen (appDefaultTheme + peek hydrate)
                                    │   ← live path for EPUB *and* PDF routes
                                    ▼
                         ReaderSettingsStore (peek / persisted / setTheme)
                                    │
                                    ▼
                         viewModel.theme (may be matchDevice)
                                    │
                    colorScheme ────┤
                                    ▼
                         resolvedTheme → light|sepia|dark
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
        applyPreferences      ReaderView(pageTheme)   preferredColorScheme
        (EPUB Readium only)   UIKit margins            (nil if matchDevice)
```

`AppReaderDefaults` stays in the app target. RishiReader receives a plain `ReaderTheme` `appDefaultTheme` parameter (no app-target import).

**Seeding invariant:** `AppReaderDefaults.theme` missing-key fallback must be `.matchDevice` (via `ReaderTheme.default`) **before** first-open seeding runs. Otherwise every first open permanently writes `.light`.

**Unused surfaces:** `PDFReaderScreen` / `ReaderToolBar` / `PDFThemePicker` are not in the production navigation graph; update only for compile parity when `ReaderTheme` gains cases.

## Testing

- Unit: `ReaderTheme` cases, rawValue, default, `resolved(isDark:)`, `preferredColorScheme` mapping helper.
- Store: missing key returns nil from `persistedTheme`; `theme(for:)` still falls back to `.default`.
- Existing picker / smoke tests updated for four cases.
- Manual: system dark → Library dark → open new EPUB → dark reader; pick Light → stays light after reopen; Settings Match Device → new book matches; Settings Dark → new book dark.

## Docs to update

- `apps/apple/docs/features/settings.md` — Match Device default; first-open seeding is real.
- `apps/apple/docs/features/reader.md` — theme list includes Match Device.
- `RishiReader+API.swift` comment for `ReaderTheme`.

## Success criteria

1. System dark + never-customized book → dark EPUB chrome and Readium dark theme (no light flash from Library).
2. Explicit Light / Sepia / Dark per book still persist and force chrome correctly.
3. Settings theme picker includes Match Device and seeds new books.
4. System appearance toggle while reading Match Device updates the reader without leaving the screen.
5. PDF books opened from Library (same `ReaderScreen` path) follow the same chrome/Readium resolution rules; page bitmaps may stay light.
