# CarPlay Audio Integration Design

> **Status:** Reviewed design; ready for implementation

## Goal

Add a production-quality CarPlay Audio experience for Rishi on iOS. A driver can open Rishi in CarPlay, browse a concise list of locally available books, resume or start narration, and use the standard Now Playing controls while the iPhone is locked or the phone scene is not active.

## Confirmed context

- The Apple target currently builds cleanly with Xcode Beta and has no CarPlay entitlement, scene role, or CarPlay delegate. The fresh baseline command was `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/rishi-carplay-baseline-current-derived`; it completed with `** BUILD SUCCEEDED **`.
- `AudioSessionCoordinator`, `ChunkedAudioPlayerTTSEngine`, `ReadAloudController`, `NowPlayingController`, and `TTSPlaybackControlling` already provide the audio ownership and remote-control foundation.
- `AppDependencies` is currently owned by the SwiftUI `App` state and is only handed to `RishiAppDelegate` after the phone scene appears. That is insufficient for a CarPlay scene that launches independently.
- `BookStore`, `PositionStore`, `BookFileStorage`, and `ReaderViewModel` already provide local book, progress, file, and publication-loading primitives.
- The Worker already exposes the authenticated streaming TTS endpoint used by the app. No CarPlay-specific worker endpoint is currently required.

## Scope

### In scope

1. Enable the approved iOS CarPlay Audio capability and add an iOS-only CarPlay template configuration while preserving the generated phone scene configuration.
2. Make one `AppDependencies` instance available to both the phone SwiftUI scene and the CarPlay scene.
3. Add an iOS-only CarPlay scene delegate and session coordinator.
4. Provide a testable catalog projection with `Continue Listening` and `Library` items, filtered to locally playable EPUB books and bounded for vehicle display. PDF narration remains out of scope until its separate reader path has a tested CarPlay adapter.
5. Start/resume narration from a CarPlay book selection through one shared MainActor playback owner used by both the phone reader and CarPlay, preserving the existing audio session and Now Playing ownership.
6. Show safe signed-out, unavailable, loading, missing-file, and allowance-failure states without requiring phone interaction while driving.
7. Refresh catalog state on CarPlay connect/reconnect and release only CarPlay UI references on disconnect; active playback remains owned by the shared audio stack.
8. Audit the Worker TTS/auth/cache/allowance contract and run its focused Bun tests. Worker source changes are out of scope unless the audit finds a concrete CarPlay incompatibility.

### Out of scope

- CarPlay Dashboard, instrument cluster, maps, navigation, voice chat, account management, paywall UI, or custom CarPlay drawing.
- Chapter browsing until a stable local chapter projection is available and Apple’s audio-template constraints justify another hierarchy.
- A second audio engine, new TTS endpoint, or duplicate Now Playing command center.
- PDF narration from CarPlay until a separate PDF reader adapter is implemented and tested.
- iPadOS or Mac Catalyst CarPlay code paths.

## Architecture

### Shared application lifetime

Add a main-actor-owned `AppDependencies.shared` instance. `rishiApp` uses that instance for its SwiftUI environment, while `CarPlaySceneDelegate` uses the same instance when CarPlay creates a scene independently. `bootstrap()` remains idempotent. The dependency graph exposes a single `ReadAloudPlaybackOwner`; phone reader screens and CarPlay both acquire a host binding from it instead of constructing independent `ReadAloudController` instances. The owner enforces one active narration/Now Playing attachment and explicit host handoff. The CarPlay scene seeds the dependency user ID from the existing Keychain session before bootstrap when available; it never presents sign-in UI in CarPlay.

### CarPlay scene

Add `CarPlaySceneDelegate` behind `#if os(iOS) && canImport(CarPlay)`. `RishiAppDelegate.application(_:configurationForConnecting:options:)` returns a CarPlay `UISceneConfiguration` only for `CPTemplateApplicationSceneSessionRoleApplication`; the existing generated phone configuration remains the fallback for the phone role. On connect, the delegate immediately installs a loading `CPListTemplate`, then asynchronously obtains services and installs a root list. The delegate retains `CPInterfaceController` for the session and clears only the CarPlay references on disconnect.

### Catalog

Keep CarPlay item projection independent from UIKit. A `CarPlayCatalogSnapshot` contains display-ready book rows with book ID, title, author, progress, and a section (`continueListening` or `library`). A loader reads the current Keychain user, books, and positions from the existing stores. A pure projection function filters to EPUB and missing local files before projection, sorts continue-listening items by most recent progress, caps the visible list, and never leaks another user’s books after account changes. Each async load captures both user ID and account-generation token, then revalidates them after every await before publishing rows.

### Playback

`ReadAloudPlaybackOwner` owns the one active narration controller, loaded reader context, playback session token, and Now Playing attachment. It exposes a small MainActor protocol with exact CarPlay operations (`start`, `toggle`, `pause`, `resume`, `next`, `previous`, `stop`) so orchestration tests do not fake the final `ReadAloudController` directly. `CarPlayPlaybackCoordinator` is a thin account-aware adapter over that owner. It constructs a candidate reader view model using `BookFileStorage.absoluteFileURL(for:)`, loads the publication, revalidates account identity, and only then hands off from the old host/session. A failed replacement leaves the old session intact. Phone reader presentation uses a host binding and cannot dispose a session owned by CarPlay.

When playback starts, the existing `NowPlayingController` publishes metadata and remote commands. The session coordinator pushes `CPNowPlayingTemplate.shared`; it does not manually duplicate play/pause/next/previous behavior. Disconnecting CarPlay leaves active audio intact so lock-screen/Bluetooth playback continues.

### Worker boundary

The CarPlay path uses the existing `WorkerTTSChunkSource` and `WorkerClient`. The worker audit verifies authenticated streaming while the app is backgrounded, cache-hit/miss behavior, speed/voice forwarding, allowance errors, and cancellation. If those contracts already pass, no Worker change is made.

## Error and lifecycle behavior

- No Keychain user: root list says to sign in on iPhone; no selection starts playback.
- Services still booting: disabled loading item; replace it after bootstrap.
- User changes or signs out: account-generation change invalidates in-flight catalog/playback work; sign-out stops the shared playback owner, detaches Now Playing, and cancels the old stream before clearing the stored user ID. CarPlay then shows the signed-out state. Account identity is revalidated after every asynchronous load before a row or playback session is published.
- Book has unsupported format or missing local file: omit it from the catalog; if it disappears between listing and selection, show a concise unavailable alert and refresh.
- Publication load fails: show an unavailable alert and leave any prior active session untouched until the replacement session is ready.
- Narration entitlement/allowance/consent failure: stop the attempted session and show a CarPlay-safe message directing the user to Rishi on iPhone.
- CarPlay disconnect: clear interface/controller references and observers and release only the CarPlay host binding; do not stop shared active playback unless account teardown or an explicit user stop requires it.

## Verification

- Pure catalog tests cover sorting, filtering, caps, user isolation, and empty/signed-out states.
- Playback coordinator tests cover selection, existing-session toggle, publication-load failure, entitlement blocking, and disconnect cleanup through injected fakes.
- Scene configuration and entitlement checks inspect the built iOS app’s Info.plist and entitlements, including both the existing phone role and the CarPlay role. A device/archive signing check must verify that the approved managed capability is present in the signed profile; simulator compilation alone is not release evidence. Mac Catalyst must compile without CarPlay source or entitlement use.
- The full Apple simulator build must pass, plus focused Apple tests.
- Worker focused tests use Bun from `workers/worker`; no npm/yarn/pnpm commands.
- A final adversarial review must report zero open Critical/High findings and re-check the app build, test output, target guards, lifecycle, and worker audit.

## Apple references

- [Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [Displaying Content in CarPlay](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay)
- [CPListTemplate](https://developer.apple.com/documentation/carplay/cplisttemplate)
- [CPNowPlayingTemplate](https://developer.apple.com/documentation/carplay/cpnowplayingtemplate)
- [CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay/)

## Research and plan review resolution

Round 1 found five High issues and one Important issue: the original design allowed duplicate `ReadAloudController`/Now Playing owners; it included PDF rows without a tested PDF narration adapter; it did not invalidate in-flight work on sign-out/account switch; its partial scene manifest could displace the phone scene; and its CarPlay tests targeted methods that do not exist on the final controller. The updated design resolves these by making a single shared playback owner authoritative, limiting the first catalog to EPUB, adding account-generation checks and sign-out teardown, configuring only the CarPlay role through `configurationForConnecting` while retaining the generated phone role, and testing an explicit CarPlay playback protocol. The review also required an explicit module-qualified delegate check, signed-profile verification, and full iOS/Mac Catalyst guards; these are now implementation and verification requirements. A second independent review recorded no open Critical/High findings before implementation.
