# Mac onboarding layout

Date: 2026-06-16
Package: `RishiOnboarding`

## Problem

All five onboarding screens (`WelcomeScreen`, `SampleOrImportScreen`,
`MicPermissionPrimer`, `NotificationsPermissionPrimer`, `FirstReaderHint`) are
built for iPhone: content sits in a `VStack` pinned to `.frame(maxWidth: .infinity,
maxHeight: .infinity)`. On a wide Mac Catalyst window the hero floats in dead
space and the primary button stretches into a full-window bar.

The iPhone layout was already polished and approved. This work must change Mac
appearance only, leaving iPhone and iPad byte-identical.

## Approach

Introduce one reusable container in the package that every screen adopts. Two
pieces:

### 1. `OnboardingLayoutMode` (pure, unit-testable)

```swift
public enum OnboardingLayoutMode: Equatable {
    case fullBleed
    case centeredColumn(maxWidth: CGFloat)

    public static func resolve(isMacCatalyst: Bool) -> OnboardingLayoutMode {
        isMacCatalyst ? .centeredColumn(maxWidth: 440) : .fullBleed
    }

    static var current: OnboardingLayoutMode {
        #if targetEnvironment(macCatalyst)
        return resolve(isMacCatalyst: true)
        #else
        return resolve(isMacCatalyst: false)
        #endif
    }
}
```

The compile-time `#if` is isolated in `current`; the decision logic
(`resolve`) is a pure function tested in isolation, matching the existing
`EPUBSpreadResolver` pattern.

Gating on `targetEnvironment(macCatalyst)` keeps iPhone and iPad unchanged.
iPad adopting the column later is a one-line change but is out of scope here.

### 2. `OnboardingScaffold<Hero, Actions>`

A container view owning spacing, padding, frame, and background for both modes.
Each screen supplies a `hero` builder and an `actions` builder and stops managing
its own structural chrome.

```swift
enum OnboardingActionPlacement { case pinnedToBottom, belowContent }

struct OnboardingScaffold<Hero: View, Actions: View>: View {
    let mode: OnboardingLayoutMode
    let actionPlacement: OnboardingActionPlacement
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var actions: () -> Actions
}
```

Layout rules:

- `.centeredColumn(maxWidth)` (Mac): `VStack(spacing: xl) { hero(); actions() }`
  constrained to `maxWidth`, padded `l`, centered in an infinite frame.
  `actionPlacement` is ignored here — Mac always renders the centered column.
- `.fullBleed` + `.pinnedToBottom` (iPhone, used by Welcome / SampleOrImport /
  FirstReaderHint): `VStack(spacing: l) { Spacer; hero(); Spacer; actions() }`.
- `.fullBleed` + `.belowContent` (iPhone, used by Mic / Notifications primers):
  `VStack(spacing: l) { hero(); actions() }.padding(l)`.

Background `RishiColor.surfaceElevated.ignoresSafeArea()` is applied by the
scaffold in all modes.

### Why `actionPlacement` exists

The two primers currently center their buttons directly under the content (no
`Spacer`, outer `.padding(l)`), while Welcome / SampleOrImport / FirstReaderHint
pin the button to the bottom edge via `Spacer`s. To preserve each screen's exact
iPhone layout, the scaffold needs to know which fullBleed arrangement to use. On
Mac the distinction disappears (always centered column).

### Screen adoption shape

Each screen wraps its icon/title/bullets-or-description in a
`VStack(spacing: l)` as the `hero` builder, and its button block as the
`actions` builder. Because the hero is its own `VStack`, internal hero spacing
stays `l` in both modes; the scaffold's outer spacing only governs the
hero-to-actions gap. This keeps the iPhone (`fullBleed`) output identical to the
current code while giving Mac a tidy `xl` gap.

## Files

- New: `Packages/RishiOnboarding/Sources/RishiOnboarding/UI/OnboardingScaffold.swift`
  (`OnboardingLayoutMode`, `OnboardingActionPlacement`, `OnboardingScaffold`).
- Edit: `WelcomeScreen.swift`, `SampleOrImportScreen.swift`,
  `MicPermissionPrimer.swift`, `NotificationsPermissionPrimer.swift`,
  `FirstReaderHint.swift` to adopt the scaffold.
- New test: `Tests/RishiOnboardingTests/OnboardingLayoutModeTests.swift`.

## Testing

- Unit-test `OnboardingLayoutMode.resolve` (Swift Testing): `isMacCatalyst: true`
  -> `.centeredColumn(maxWidth: 440)`; `false` -> `.fullBleed`. Written red first.
- Existing construct-smoke tests in `OnboardingUITests` must stay green.
- `swift test --package-path Packages/RishiOnboarding` is the package gate.
- Main orchestrator runs a Mac Catalyst `xcodebuild` after package work to
  confirm the integrated build, then visual confirmation in the running app.

## Out of scope

- iPad column adoption.
- Main app screens (library / reader / settings) Mac width audit.
- Any iPhone visual change.
