# Platform enum — unify mac/Catalyst/iOS branching

Date: 2026-06-18
Status: Approved (design)

## Problem

`apps/apple` branches on platform with ~190 `#if` sites across ~30 files.
There is no single platform helper. The UI layer uses
`#if targetEnvironment(macCatalyst)` in 51 places to unlock "Mac experience"
behavior (menu bar, window sizing, PDF layout modes, overscroll page turn).
These were always intended to mean "macOS **and** Mac Catalyst together" — the
two should behave identically. Scattering the directive makes that intent
implicit and easy to get wrong.

## Goal

Introduce one shared `Platform` helper that classifies the target as `.mac`
(macOS OR Mac Catalyst), `.iOS` (iOS simulator or physical iPhone/iPad), or
`.unsupported`, and replace every `#if targetEnvironment(macCatalyst)` UI branch
with a runtime check against it. After this change, the only surviving
`targetEnvironment(macCatalyst)` directives are (1) inside the helper itself and
(2) the audio capability guards (see Non-goals).

## The type

New file: `apps/apple/Packages/RishiCore/Sources/RishiCore/Models/Platform.swift`

```swift
public enum Platform: Sendable {
    case mac          // macOS OR Mac Catalyst
    case iOS          // iOS simulator OR physical iPhone/iPad
    case unsupported  // everything else (watchOS, tvOS, Linux, ...)

    public static let current: Platform = {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return .mac
        #elseif os(iOS)
        return .iOS
        #else
        return .unsupported
        #endif
    }()
}
```

- `static let`: resolved once, constant-foldable.
- Bare enum — no `isMac`/`isIOS` convenience accessors. Call sites use
  `Platform.current == .mac` or `switch Platform.current`.
- `Sendable` for Swift 6 strict concurrency (default-isolation = MainActor stays
  the project default; the type itself is concurrency-safe to read anywhere).
- Lives in `RishiCore`: the one module every package and the app target already
  import. Zero new dependency edges; `RishiCore` has no local deps so no cycle.

## Migration

### In scope — convert all 51 `#if targetEnvironment(macCatalyst)` → runtime

Every one of the 51 `#if targetEnvironment(macCatalyst)` sites becomes:

```swift
if Platform.current == .mac { ... }
```

These sites were verified to reference only APIs that compile on the iOS target
(UIKit, PDFKit, SwiftUI, Foundation — e.g. `UIWindowScene.sizeRestrictions`,
`PDFView` config, `CommandMenu`, layout math). A runtime `if` keeps both
branches in the binary, so the `.mac` branch must compile on iOS; all 51 do.
There is no compile-guard remainder.

Two structural sub-cases:

1. **Nested imports.** Where a Catalyst block contained an inner
   `import UIKit` / `import PDFKit`, hoist that import to a top-level
   `#if canImport(UIKit)` (still compile-time) so the body compiles
   unconditionally; the runtime `if` then gates behavior.
2. **Whole-type guards.** Where an entire type was Catalyst-only (e.g.
   `PDFOverscrollPageTurnDetector`), the type now always compiles (harmless,
   unused on iOS); the runtime `if` gates instantiation/use. Mac-only behavior
   is preserved at runtime.

### Out of scope — left exactly as-is

- **~96 `#if canImport(...)` import / type-availability guards** (UIKit,
  AVFAudio, SafariServices, PDFKit, BackgroundTasks, MediaPlayer,
  AuthenticationServices, CoreML, FoundationNetworking, AudioToolbox). A runtime
  enum cannot conditionally `import` or reference a type absent on a platform.
- **13 `#if !os(macOS)` UI sites.** On Mac Catalyst, `!os(macOS)` is `true`, so
  these run on **both** iOS and Catalyst today. Converting to
  `Platform.current == .iOS` would wrongly exclude Catalyst (`.mac`). They are an
  "exclude pure-macOS" guard, not a `macCatalyst` directive, and pure macOS is
  not a shipping target. Left unchanged.
- **Audio capability branches** `#if !os(macOS) || targetEnvironment(macCatalyst)`
  (RishiVoice WebRTC audio, audio-format selection). These mean
  "UIKit-audio-runtime" — iOS *and* Catalyst grouped together, the **opposite**
  of `.mac`. Converting would invert their meaning. Left compile-time; the
  `targetEnvironment(macCatalyst)` token survives here for the opposite reason
  (Catalyst behaving like iOS).
- **`UIDevice.current.userInterfaceIdiom == .pad`** checks — iPad-vs-iPhone is an
  orthogonal axis, not this enum. Unchanged.

## Testing & verification

- `PlatformTests` (Swift Testing) in `RishiCoreTests`: assert
  `Platform.current == .iOS` on the iOS simulator runner; assert the type is
  `Sendable` / exhaustively switchable. The `.mac` branch cannot be asserted
  from the iOS runner — it is covered by the build (it must compile and the
  Catalyst slice must link).
- Per `apps/apple/CLAUDE.md`, build-green is the real gate. After each package's
  sites are converted, build that package. Because runtime `if` no longer
  dead-strips the other platform's branch, **both** the iOS slice (iPhone 17)
  and the Mac Catalyst slice must compile and pass. The main orchestrator runs
  the full `xcodebuild` (iPhone 17 + Catalyst, `ENABLE_USER_SCRIPT_SANDBOXING=NO`
  for Catalyst) as the end gate, confirming the literal
  `** BUILD SUCCEEDED **` marker.
- Migration is per-file, build-verified — not a blind find-replace.

## Non-goals

- No changes to underlying engines (Readium, PDFKit, database layer, StoreKit,
  AVFoundation).
- No `project.pbxproj` edits (synchronized groups; new file is picked up
  automatically).
- No build-flag / xcconfig changes (runtime enum, not custom `-D` directives).
- No `.planning/` commits. Commits limited to `Packages/`, `rishi/`, `docs/`.

## Affected packages (approx.)

RishiReader (PDF/EPUB UI, largest share), RishiSettings, RishiLibrary,
RishiVoice (audio-format test only — capability guards untouched), plus the app
target `rishi/rishi/Mac/` (menu commands) and `rishi/rishi/Reader/`. `RishiCore`
gains the new type. Each touched package is built individually, then the
integrated app build is the final gate.
