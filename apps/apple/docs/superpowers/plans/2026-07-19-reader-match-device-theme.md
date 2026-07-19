# Reader Match Device theme — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Spec:** `apps/apple/docs/superpowers/specs/2026-07-19-reader-match-device-theme-design.md`
>
> **Revision history:** R1: live `ReaderScreen` path, seeding hazard, no `Bool?` API, Mac tags. R2: `ReaderView(pageTheme:)`, Settings in Task 1 gate, peek API, EPUB-only prefs. R3: hydrate once in `ReaderDestination.init` (NOT `ReaderScreen.init` — struct init re-runs and would reset in-session picker changes); `.task` seeds only when missing (no theme re-assign); Task 1+3 paint paths must not leave Match Device stuck on light.
>
> **Testing note:** Update tests that break. Add focused unit tests for `resolved(isDark:)` and `persistedTheme` / peek. No UI snapshots.
>
> **Build-clean:** Do NOT invoke `xcodebuild rishi` from subagents. After Task 1, every commit must leave **both** `RishiReader` and `RishiSettings` package tests green. Never use `--filter` as a substitute for package greenness once `matchDevice` exists.

**Goal:** Apple Books–style Match Device reader theming so Library → reader does not flash light on a dark system; Settings defaults seed on first open; Light / Sepia / Dark remain explicit overrides.

**Architecture:** `ReaderTheme.matchDevice` as `.default`. Resolve against `@Environment(\.colorScheme)` for Readium prefs **and** `ReaderView` UIKit margins. Sync-hydrate theme before first paint; async `.task` only seeds missing keys. Live path: **`ReaderScreen` for EPUB and PDF routes**.

**Tech Stack:** Swift 6, SwiftUI, Readium Navigator, `ReaderSettingsStore` / `AppReaderDefaults`.

---

## Critical facts

1. **Nav:** `.epub` / `.pdf` → `ReaderDestination` → **`ReaderScreen`** → **`ReaderView`**. `PDFReaderScreen` / `ToolBar` / `PDFThemePicker` = compile parity only.
2. **Live theme sheet:** `EPUBThemePicker` (including PDF books).
3. **`ReaderView` paints margins from UIKit** via `backgroundUIColor(viewModel.theme)` in `make/updateUIViewController`. Passing resolved theme only into SwiftUI `ReaderScreen` backgrounds is **not enough** — `ReaderView` must receive the resolved page theme or it keeps light margins under `matchDevice` and **will not refresh on system appearance change** (UIKit update only runs when SwiftUI inputs change).
4. **`applyPreferences()` is EPUB-only** (`EPUBNavigatorViewController` cast). PDF theming on the live path = SwiftUI chrome + `ReaderView` margins (page bitmaps stay authored).
5. **Seeding hazard:** Change `AppReaderDefaults` fallback to `.default` **before/with** first-open seed writes.
6. **First-frame flash / hydration placement:** Sync-hydrate **once** in `ReaderDestination.init` (before `@State` capture of the VM). **Never** hydrate in `ReaderScreen.init` — `ReaderScreen` is a struct re-created on body refreshes; re-peeking would overwrite in-session picker changes before async `setTheme` lands. After hydrate, `.task` only **seeds** when the per-book key is missing — it must not re-assign `viewModel.theme`.
7. **Task 1 alone paints Match Device as light** (defensive switch arms). Do not stop after Task 1 on a dark-system device build; land Task 3 in the same PR / same day so resolved `pageTheme` ships.
8. **Mac menu tags `ReaderTheme`**. `MacReaderTheme` is only for `MacCommandIntent`.
9. **No cross-client theme sync today.**

---

## File map

| File | Role |
|------|------|
| `Model/ReaderTheme.swift` | `matchDevice`, `.default`, `resolved(isDark:)` |
| `UI/ReaderTheme+ColorScheme.swift` | `preferredColorScheme: ColorScheme?` |
| `Storage/ReaderSettingsStore.swift` | `persistedTheme` + sync `peekPersistedTheme` with defaults |
| `UserDefaultsReaderSettingsStore.swift` | Real peek/persisted impl |
| `Ephemeral*` + preview stores | Inherit protocol defaults |
| `EPUBPreferencesBridge.swift` | Exhaustive switch |
| `ReaderScreen.swift` | Seed (missing only), resolve, chrome, onChange, pass `pageTheme` |
| `EPUB/ReaderView.swift` | **Use resolved page theme for UIKit margins** |
| `EPUBThemePicker.swift` | Match Device label/swatch |
| Dead-path PDF files | Compile parity switches only |
| `AppReaderDefaultsBindings.swift` | Fallback `.default` |
| `ReaderDestination.swift` | **Sync theme hydrate once** + pass `appDefaultTheme` |
| `ReaderDefaultsSection.swift` | Match Device label (**Task 1**) |
| Mac menu / intent files | Task 4 |
| Docs | Task 5 |

---

### Task 1: Enum + all exhaustive switches (RishiReader **and** RishiSettings green)

**Files:**
- `ReaderTheme.swift`, `ReaderTheme+ColorScheme.swift`, `ReaderThemeTests.swift`
- All RishiReader switches: bridge, pickers, `ReaderView`, `PDFReaderView`, `ReaderScreen` backgrounds/chrome, `PDFReaderScreen`, `ToolBar`
- **`Packages/RishiSettings/.../Reader/ReaderDefaultsSection.swift`** (label switch — must ship in this commit)

- [ ] **Step 1: `ReaderTheme.swift`**

```swift
import Foundation

public enum ReaderTheme: String, Codable, CaseIterable, Sendable, Hashable {
    case matchDevice
    case light
    case sepia
    case dark

    public static let `default`: ReaderTheme = .matchDevice

    public func resolved(isDark: Bool) -> ReaderTheme {
        switch self {
        case .matchDevice: return isDark ? .dark : .light
        case .light, .sepia, .dark: return self
        }
    }
}
```

- [ ] **Step 2: `ReaderTheme+ColorScheme.swift`**

```swift
import SwiftUI

extension ReaderTheme {
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .matchDevice: return nil
        case .dark: return .dark
        case .light, .sepia: return .light
        }
    }
}
```

- [ ] **Step 3: Exhaustive switches**

Pickers / Settings labels — add Match Device:

```swift
case .matchDevice: return "Match Device"
// swatch: Color.primary.opacity(0.35)
```

Background helpers — add defensive arm (Task 3 replaces live call sites with resolved theme):

```swift
case .matchDevice: return /* same as .light */
```

Bridge:

```swift
case .matchDevice: return .light // callers must pass resolved
```

Chrome:

```swift
.preferredColorScheme(viewModel.theme.preferredColorScheme)
```

`ReaderDefaultsSection.label(for:)` — same four cases as pickers.

- [ ] **Step 4: Tests** — update `ReaderThemeTests` for four cases, `.default == .matchDevice`, `resolved(isDark:)`. Optionally assert `preferredColorScheme` mapping in a small SwiftUI-aware test or same suite if ColorScheme is importable.

- [ ] **Step 5: Green gate (both packages)**

```bash
swift test --package-path apps/apple/Packages/RishiReader
swift test --package-path apps/apple/Packages/RishiSettings
```

Both must PASS before commit.

- [ ] **Step 6: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(reader): add Match Device theme with exhaustive switch updates

EOF
)"
```

---

### Task 2: Persist API — async `persistedTheme` + sync `peekPersistedTheme`

**Files:** `ReaderSettingsStore.swift`, `UserDefaultsReaderSettingsStore.swift`, tests. Preview/ephemeral stores inherit defaults (no edits if extension provides defaults).

- [ ] **Step 1: Protocol + defaults**

```swift
public protocol ReaderSettingsStore: Sendable {
    func theme(for bookId: BookID) async -> ReaderTheme
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async
    func persistedTheme(for bookId: BookID) async -> ReaderTheme?
    /// Synchronous peek for first-frame hydration. Default `nil`.
    func peekPersistedTheme(for bookId: BookID) -> ReaderTheme?
    // typography unchanged...
}

public extension ReaderSettingsStore {
    func persistedTheme(for bookId: BookID) async -> ReaderTheme? {
        peekPersistedTheme(for: bookId)
    }
    func peekPersistedTheme(for bookId: BookID) -> ReaderTheme? { nil }
    // existing typography defaults...
}
```

- [ ] **Step 2: `UserDefaultsReaderSettingsStore`**

```swift
    public func peekPersistedTheme(for bookId: BookID) -> ReaderTheme? {
        let key = themeKey(bookId)
        guard let raw = defaults.string(forKey: key),
              let theme = ReaderTheme(rawValue: raw) else { return nil }
        return theme
    }

    public func theme(for bookId: BookID) async -> ReaderTheme {
        peekPersistedTheme(for: bookId) ?? .default
    }
```

(No need to override `persistedTheme` if extension delegates to peek.)

- [ ] **Step 3: Tests** — nil when empty; round-trip including `.matchDevice`; `peek` matches async.

- [ ] **Step 4: Verify + commit**

```bash
swift test --package-path apps/apple/Packages/RishiReader
swift test --package-path apps/apple/Packages/RishiSettings
```

```bash
git commit -m "$(cat <<'EOF'
feat(reader): add sync peek and async persisted theme APIs

EOF
)"
```

---

### Task 3: Live path — hydrate, seed, resolve into Readium **and** `ReaderView`

**Files:** `ReaderDestination.swift`, `ReaderScreen.swift`, `ReaderView.swift`, `AppReaderDefaultsBindings.swift`

**Do not merge with Task 1 in separate PRs without Task 3** — after Task 1, Match Device still paints light until this task lands.

- [ ] **Step 1: `AppReaderDefaults` fallback** (must be first)

```swift
else { return .default }
```

- [ ] **Step 2: Sync-hydrate once in `ReaderDestination.init`**

`ReaderViewModel` is a class; hydrate **before** wrapping in `@State`, and **never** in `ReaderScreen.init` (struct init re-runs on body refresh and would clobber in-session picker selections).

Current `ReaderDestination.init` takes `vm:` already constructed. Change to hydrate immediately after receiving it:

```swift
    init(
        vm: ReaderViewModel,
        services: BootstrappedServices,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        let peeked = services.readerSettingsStore.peekPersistedTheme(for: vm.book.id)
        let initial = peeked ?? services.readerDefaults.theme
        vm.theme = initial
        // Close seed race: if missing, write immediately so an early in-reader
        // picker persist cannot lose a later cold-open seed write.
        if peeked == nil {
            let store = services.readerSettingsStore
            let bookId = vm.book.id
            Task { await store.setTheme(initial, for: bookId) }
        }

        self._vm = State(initialValue: vm)
        self.services = services
        self.userId = userId
        self.onRequestPaywall = onRequestPaywall
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: services.voicePresenter,
            voiceLanguageProvider: { services.readerDefaults.voiceLanguage },
            entitlementSnapshotStore: services.entitlementSnapshotStore,
            onRequestPaywall: onRequestPaywall
        ))
    }
```

- [ ] **Step 3: `appDefaultTheme` on `ReaderScreen`**

```swift
    private let appDefaultTheme: ReaderTheme

    public init(
        ...,
        appDefaultTheme: ReaderTheme = .default,
        ...
    ) {
        ...
        self.appDefaultTheme = appDefaultTheme
        // Do NOT assign viewModel.theme here.
    }
```

Wire:

```swift
        ReaderScreen(
            viewModel: vm,
            readerSettingsStore: services.readerSettingsStore,
            appDefaultTheme: services.readerDefaults.theme,
            // ...existing args
```

- [ ] **Step 4: Async seed only when missing** (existing `.task`, after `load()`)

**Delete** the current line that assigns theme from the store (~L291 today: `viewModel.theme = await settings.theme(for:)`). Do **not** re-assign `viewModel.theme` — Destination already hydrated (and may have started a seed write).

Keep a defensive seed in case Destination’s fire-and-forget Task has not completed:

```swift
            if let settings = readerSettingsStore {
                if await settings.persistedTheme(for: viewModel.book.id) == nil {
                    await settings.setTheme(appDefaultTheme, for: viewModel.book.id)
                }
                viewModel.typography = await settings.typography(
                    for: viewModel.book.id
                )
            }
```

- [ ] **Step 5: Resolve + pass `pageTheme` into `ReaderView` (atomic)**

On `ReaderScreen`:

```swift
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedTheme: ReaderTheme {
        viewModel.theme.resolved(isDark: colorScheme == .dark)
    }
```

**`ReaderView` checklist (no default for `pageTheme` — update all together):**
1. Add `public let pageTheme: ReaderTheme`
2. Thread through `init`
3. `makeUIViewController` / `updateUIViewController` use `backgroundUIColor(pageTheme)` — stop using `viewModel.theme` for margins
4. Keep defensive `case .matchDevice` in `backgroundUIColor` as dead-code guard only

Sole production callsite (`ReaderScreen` ~L141):

```swift
        ReaderView(
            viewModel: viewModel,
            pageTheme: resolvedTheme,
            // ...existing callbacks unchanged
```

Also on `ReaderScreen`:
- SwiftUI `background` / `readerBarColor` switches → `resolvedTheme`
- `applyPreferences()` → `theme: resolvedTheme`
- Chrome → `.preferredColorScheme(viewModel.theme.preferredColorScheme)`

- [ ] **Step 6: System appearance change**

Beside `.onChange(of: viewModel.theme)`:

```swift
            .onChange(of: colorScheme) { _, _ in
                guard viewModel.theme == .matchDevice else { return }
                applyPreferences() // EPUB Readium only; no-op for PDF navigators
            }
```

`pageTheme: resolvedTheme` changing also drives `ReaderView.updateUIViewController` for margins (EPUB + PDF).

- [ ] **Step 7: Verify + commit**

```bash
swift test --package-path apps/apple/Packages/RishiReader
swift test --package-path apps/apple/Packages/RishiSettings
```

```bash
git commit -m "$(cat <<'EOF'
feat(reader): hydrate Match Device theme and resolve into Readium and margins

EOF
)"
```

---

### Task 4: Mac menu + intent enum

**Files:** `RishiMenuCommands.swift`, `RishiKeyboardCommands.swift`, `MacCommandDispatchModifier.swift`, Mac tests if needed.

Settings **labels already done in Task 1.** This task is Mac-only (+ any Settings footer copy tweak if desired).

- [ ] **Step 1: `ThemeMenuItems`**

```swift
        Picker("Theme", selection: prefs?.theme ?? .constant(.default)) {
            Text("Match Device").tag(ReaderTheme.matchDevice)
            Text("Light").tag(ReaderTheme.light)
            Text("Sepia").tag(ReaderTheme.sepia)
            Text("Dark").tag(ReaderTheme.dark)
        }
```

- [ ] **Step 2: `MacReaderTheme` + map**

```swift
enum MacReaderTheme: String, Equatable, Sendable {
    case matchDevice, light, sepia, dark
}
```

Map all four in `MacCommandDispatchModifier`.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(settings): add Match Device to Mac reader theme menus

EOF
)"
```

---

### Task 5: Docs + grep + manual checklist

- [ ] **Step 1: Docs** (`settings.md`, `reader.md`, `RishiReader+API.swift`)

  - Four themes; default Match Device.
  - Seeding: **any book without a per-book theme key** on open (not only newly imported). Update Settings footer if it still says only “new books” without that nuance.
  - Do not claim font-family seeding.
  - Live PDF/EPUB both use `ReaderScreen` / `ReaderView` theming; Readium CSS apply is EPUB-only.

- [ ] **Step 2: Grep**

```bash
rg -n "exactly three themes|default == \\.light|allCases == \\[\\.light|theme == \\.dark \\? \\.dark" apps/apple --glob '*.swift' --glob '*.md'
```

- [ ] **Step 3: Final tests**

```bash
swift test --package-path apps/apple/Packages/RishiReader
swift test --package-path apps/apple/Packages/RishiSettings
```

- [ ] **Step 4: Manual checklist**

1. System Dark → Library dark → never-themed book → dark reader, **no light flash** on open.
2. Pick Light in-reader → reopen → light, no flash.
3. Settings → Dark → never-themed book → opens dark immediately.
4. Match Device → toggle Control Center appearance while reading → Readium page (EPUB) **and** margins update.
5. Sepia → sepia page + light chrome.
6. PDF from Library → margins/chrome follow resolved theme; page bitmap may stay light; appearance toggle updates margins.

- [ ] **Step 5: Commit docs**

```bash
git commit -m "$(cat <<'EOF'
docs(apple): document Match Device reader theme behavior

EOF
)"
```

---

## Spec coverage

| Requirement | Task |
|-------------|------|
| `matchDevice` + default | 1 |
| Settings/RishiReader switches compile together | 1 |
| peek/persisted APIs | 2 |
| Defaults fallback + Destination hydrate + seed-only + resolve into Readium **and** `ReaderView` | 3 |
| Mac UI | 4 |
| Docs / verification | 5 |

## Out of scope

- Wiring `PDFReaderScreen` into navigation
- Font-family first-open seeding
- Electron / worker theme sync
- App-wide Library appearance override
- PDF page bitmap invert

## Commit rule

After Task 1: every commit keeps `RishiReader` **and** `RishiSettings` `swift test` green.
