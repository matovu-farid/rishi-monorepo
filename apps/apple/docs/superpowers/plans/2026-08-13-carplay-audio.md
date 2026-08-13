# CarPlay Audio Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-quality iOS CarPlay Audio experience that browses local books, starts/resumes Rishi narration, and exposes standard Now Playing controls while preserving one shared audio/dependency lifetime.

**Architecture:** Add the approved `com.apple.developer.carplay-audio` capability and an iOS-only `CPTemplateApplicationSceneDelegate`. Share one `AppDependencies` instance between SwiftUI and CarPlay so the scene can launch independently. Add one account-scoped MainActor `ReadAloudPlaybackOwner`, retained by the shared dependency graph, and migrate the phone reader and CarPlay to host that owner; no host may construct a second active `ReadAloudController` or Now Playing attachment. Keep catalog projection pure and UIKit-free; keep scene/template code thin.

**Tech Stack:** Swift 6, SwiftUI, CarPlay templates, AVFoundation/MediaPlayer, Readium, Swift Testing, Xcode 27/iOS 18.4 simulator, Bun worker tests.

---

## Requirements and current-state evidence

- The baseline Apple build succeeds with Xcode Beta and the current repository state.
- [`apps/apple/rishi/rishi/rishi.entitlements`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/rishi.entitlements) has no CarPlay key.
- [`apps/apple/rishi/rishi/Info.plist`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Info.plist) has no `CPTemplateApplicationSceneSessionRoleApplication` scene configuration; because the target currently generates the phone scene manifest, the implementation will add the CarPlay role through `RishiAppDelegate.application(_:configurationForConnecting:options:)` and preserve the generated phone fallback.
- [`apps/apple/rishi/rishi/rishiApp.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/rishiApp.swift) owns the only `AppDependencies` instance through SwiftUI state; CarPlay cannot depend on the phone scene appearing first.
- [`apps/apple/rishi/rishi/Audio/ReadAloudController.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Audio/ReadAloudController.swift) already exposes `startReader(vm:)`, `togglePlayback()`, `previous()`, `next()`, `stop()`, and `TTSPlaybackControlling` conformance, but it is final and cannot be used as a direct fake. The new owner protocol will expose exact CarPlay operations and adapt this implementation.
- [`apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/TTS/NowPlayingController.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/TTS/NowPlayingController.swift) already owns lock-screen/remote command integration.
- The Worker’s existing authenticated TTS stream is the intended CarPlay backend; no new endpoint is planned.

## Files and ownership map

| File | Responsibility |
|---|---|
| `apps/apple/rishi/rishi/rishi.entitlements` | iOS CarPlay Audio entitlement only |
| `apps/apple/rishi/rishi/AppDependencies.swift` | One shared dependency instance for phone and CarPlay |
| `apps/apple/rishi/rishi/rishiApp.swift` | Consume the shared dependency instance without changing phone behavior |
| `apps/apple/rishi/rishi/Audio/ReadAloudPlaybackOwner.swift` | One account-scoped narration/Now Playing owner and phone/CarPlay host bindings |
| `apps/apple/rishi/rishi/Reader/ReaderDestination.swift` | Migrate phone reader from a local controller to the shared owner |
| `apps/apple/rishi/rishi/AppDependencies+Billing.swift` | Stop/invalidate shared playback before sign-out clears identity |
| `apps/apple/rishi/rishi/CarPlay/CarPlayCatalog.swift` | Pure EPUB catalog rows/projection and async store loader with generation checks |
| `apps/apple/rishi/rishi/CarPlay/CarPlayPlaybackCoordinator.swift` | Account-aware adapter over the shared playback owner |
| `apps/apple/rishi/rishi/CarPlay/CarPlaySessionCoordinator.swift` | Templates, interface-controller lifecycle, account/error states |
| `apps/apple/rishi/rishi/CarPlay/CarPlaySceneDelegate.swift` | `CPTemplateApplicationSceneDelegate` adapter, iOS/CarPlay guarded |
| `apps/apple/rishi/rishiTests/CarPlay/CarPlayCatalogTests.swift` | Pure catalog behavior |
| `apps/apple/rishi/rishiTests/CarPlay/CarPlayPlaybackCoordinatorTests.swift` | Playback orchestration behavior with fakes |
| `apps/apple/rishi/rishiTests/CarPlay/CarPlaySessionCoordinatorTests.swift` | Session/account/template state behavior |
| `apps/apple/rishi/rishiTests/AppDependenciesBootstrapTests.swift` | Shared dependency identity/bootstrap regression coverage |
| `apps/apple/rishi/rishiTests/ReadAloudPlaybackOwnerTests.swift` | Single-owner, host handoff, and account teardown coverage |
| `workers/worker/src/audio-speech.test.ts`, `audio-speech-cache.test.ts`, `usage/api-usage-routes.test.ts` | Focused Worker contract audit; modify only if a failing contract requires it |

The Xcode project uses a filesystem-synchronized source group, so new files under `rishi/CarPlay` and `rishiTests/CarPlay` must not be manually inserted into `project.pbxproj`.

## Implementation order

1. Configuration and shared lifetime.
2. Pure catalog projection.
3. Playback coordinator.
4. CarPlay session/templates and scene delegate.
5. Worker contract audit and full verification.

The CarPlay scene must not be wired until the pure catalog and playback seams have failing tests and passing implementations.

### Task 1: Add CarPlay configuration and shared dependency lifetime

**Files:**
- Modify: `apps/apple/rishi/rishi/rishi.entitlements`
- Modify: `apps/apple/rishi/rishi/AppDependencies.swift`
- Modify: `apps/apple/rishi/rishi/rishiApp.swift`
- Test: `apps/apple/rishi/rishiTests/AppDependenciesBootstrapTests.swift`

- [ ] **Step 1: Add the failing identity test.** Add a Swift Testing case proving that the app-facing dependency accessor returns the same reference each time and that `rishiApp` can use it without constructing a second graph. The expected shape is:

```swift
@Test("the phone and CarPlay hosts use one AppDependencies instance")
func sharedInstanceIsStable() {
    #expect(AppDependencies.shared === AppDependencies.shared)
}
```

- [ ] **Step 2: Run the focused test and confirm the intended RED failure.**

Run from the repository root:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task1-red-derived \
  -only-testing:rishiTests/AppDependenciesBootstrapTests
```

Expected: FAIL because `AppDependencies.shared` does not exist yet.

- [ ] **Step 3: Implement the shared owner.** Add `@MainActor static let shared = AppDependencies()` to `AppDependencies`, change `rishiApp`’s state initialization to `@State private var deps = AppDependencies.shared`, and leave `AppDependencies.bootstrap()` idempotent. Do not change the existing sign-in/sign-out service graph behavior.

- [ ] **Step 4: Add the approved iOS capability.** Add this boolean to `rishi.entitlements` only (not `rishi-mac.entitlements`):

```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

Do not add a partial `UIApplicationSceneManifest` to `Info.plist`. Task 4 will add `RishiAppDelegate.application(_:configurationForConnecting:options:)` behind `#if os(iOS) && canImport(CarPlay)`, return a `UISceneConfiguration` named `CarPlaySceneConfiguration` with `CPTemplateApplicationScene` and `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate` only for `CPTemplateApplicationSceneSessionRoleApplication`, and return the existing generated `Default Configuration` for the phone role. This keeps the generated phone scene as part of the same complete configuration source.

- [ ] **Step 5: Run the focused test and configuration checks.**

Run the focused Apple tests again and inspect the built product:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task1-green-derived \
  -only-testing:rishiTests/AppDependenciesBootstrapTests

codesign -d --entitlements :- /private/tmp/rishi-carplay-task1-green-derived/Build/Products/Debug-iphonesimulator/rishi.app 2>/dev/null
```

Expected: focused tests pass. The CarPlay scene configuration is verified in Task 4 after the delegate exists. If the entitlement is rejected by local signing because the installed profile does not have Apple’s approved capability, record that as an external provisioning prerequisite and continue simulator-only compilation without weakening the source entitlement.

- [ ] **Step 6: Commit the configuration/lifetime slice.**

```bash
git add apps/apple/rishi/rishi/rishi.entitlements \
  apps/apple/rishi/rishi/AppDependencies.swift apps/apple/rishi/rishi/rishiApp.swift \
  apps/apple/rishi/rishiTests/AppDependenciesBootstrapTests.swift
git commit -m "feat: share dependencies with CarPlay"
```

### Task 2: Build and test a pure CarPlay catalog projection

**Files:**
- Create: `apps/apple/rishi/rishi/CarPlay/CarPlayCatalog.swift`
- Create: `apps/apple/rishi/rishiTests/CarPlay/CarPlayCatalogTests.swift`

- [ ] **Step 1: Write failing pure tests.** Cover these exact behaviors:

```swift
@Test("catalog excludes unsupported formats and other users")
func filtersToPlayableCurrentUserBooks() { /* assert only epub rows remain */ }

@Test("continue listening is newest position first and library is title sorted")
func sortsSectionsDeterministically() { /* assert section order and IDs */ }

@Test("catalog caps each section for vehicle display")
func capsRows() { /* assert max rows are retained */ }

@Test("empty positions do not create continue listening rows")
func omitsUnstartedBooks() { /* assert empty continue section */ }
```

The tests must use real `Book`, `Position`, and `CarPlayCatalogSnapshot` values, not UIKit mocks. PDF rows are explicitly excluded until the separate PDF reader path has a tested adapter.

- [ ] **Step 2: Run only the catalog tests and confirm RED.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task2-red-derived \
  -only-testing:rishiTests/CarPlay/CarPlayCatalogTests
```

Expected: compile/test failure because the catalog types and projection do not exist.

- [ ] **Step 3: Implement the minimal pure projection.** Define `CarPlayCatalogSection`, `CarPlayBookRow`, and `CarPlayCatalogSnapshot` as `Sendable`/`Equatable`. Implement a pure function taking current user ID, books, positions, and a per-section cap. Filter to `.epub` only, require `book.userId == currentUserID`, derive continue rows only for `0 < percentComplete < 1`, sort continue rows by `Position.updatedAt` descending, sort library rows by localized case-insensitive title then ID, and apply the cap deterministically.

- [ ] **Step 4: Add the async store loader.** Add a `CarPlayCatalogLoader` that reads `books(for:)` and `position(for:)` from the existing `BookStore`/`PositionStore`, resolves `BookFileStorage.absoluteFileURL(for:)`, and excludes missing files before calling the pure projection. Capture `(userID, accountGeneration)` before the first await, revalidate both after each store/file await, and discard stale results. Read the current user from the injected user-ID provider, never from a stale cached catalog.

- [ ] **Step 5: Run catalog tests GREEN and refactor only after green.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task2-green-derived \
  -only-testing:rishiTests/CarPlay/CarPlayCatalogTests
```

Expected: all catalog tests pass.

- [ ] **Step 6: Commit the catalog slice.**

```bash
git add apps/apple/rishi/rishi/CarPlay/CarPlayCatalog.swift \
  apps/apple/rishi/rishiTests/CarPlay/CarPlayCatalogTests.swift
git commit -m "feat: project a CarPlay reading catalog"
```

### Task 3: Add one shared playback owner and migrate phone playback

**Files:**
- Create: `apps/apple/rishi/rishi/CarPlay/CarPlayPlaybackCoordinator.swift`
- Create: `apps/apple/rishi/rishiTests/CarPlay/CarPlayPlaybackCoordinatorTests.swift`
- Create: `apps/apple/rishi/rishi/Audio/ReadAloudPlaybackOwner.swift`
- Create: `apps/apple/rishi/rishiTests/ReadAloudPlaybackOwnerTests.swift`
- Modify: `apps/apple/rishi/rishi/Reader/ReaderDestination.swift`
- Modify: `apps/apple/rishi/rishi/AppDependencies.swift`
- Modify: `apps/apple/rishi/rishi/AppDependencies+Billing.swift`
- Read/modify only as needed: `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`, `NowPlayingController.swift`

- [ ] **Step 1: Write failing owner/coordinator tests.** Use an explicit `@MainActor` playback-owner protocol and fake owner; do not attempt to fake final `ReadAloudController` directly. Cover:

```swift
@Test("selecting a book loads it and starts narration from its saved position")
func selectionStartsNarration() async { /* assert load, startReader, and activeBookID */ }

@Test("selecting the active book toggles the existing session")
func activeSelectionTogglesPlayback() async { /* assert no duplicate controller */ }

@Test("failed publication load leaves an existing session intact")
func replacementLoadFailurePreservesActiveSession() async { /* assert old session remains */ }

@Test("entitlement block is returned without starting audio")
func entitlementFailureDoesNotStartNarration() async { /* assert no start */ }

@Test("disconnect releases CarPlay references but not shared playback")
func disconnectDoesNotStopSharedAudio() async { /* assert controller is retained by shared stack */ }

@Test("phone and CarPlay handoff cannot create duplicate Now Playing ownership")
func crossHostHandoffUsesOneOwner() async { /* assert one controller/session and explicit host release */ }

@Test("sign-out stops playback and invalidates stale account work")
func signOutTearsDownOutgoingAccount() async { /* assert stop, dispose, detach, and stale rejection */ }
```

- [ ] **Step 2: Run the coordinator tests and confirm RED.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task3-red-derived \
  -only-testing:rishiTests/CarPlay/CarPlayPlaybackCoordinatorTests
```

Expected: compile/test failure because the coordinator and test seams do not exist.

- [ ] **Step 3: Implement `ReadAloudPlaybackOwner`.** Keep it `@MainActor`, retain it in the shared dependency graph, and expose an account-scoped host binding plus exact operations: `start`, `toggle`, `pause`, `resume`, `next`, `previous`, and `stop`. The owner is the only code allowed to create/dispose `ReadAloudController` and attach/detach `NowPlayingController`. It serializes replacement: load a candidate reader first, revalidate account identity/generation, then stop/dispose the old controller and install the candidate. A failed candidate leaves the old controller/session intact. Releasing a phone host must not stop a CarPlay-owned session, and vice versa. Sign-out must stop, flush, dispose, invalidate the playback token, and detach Now Playing before the stored user ID is cleared.

- [ ] **Step 4: Migrate the phone reader.** Replace the local `ReadAloudController` construction in `ReaderDestination` with a host binding from the shared owner. Preserve existing reader callbacks and UI behavior. Its `dispose`/`stop` path must release only its host binding and must not tear down a session currently owned by CarPlay. Update `AudioRuntime`/service construction so the owner uses the existing TTS engine, state, settings, prewarmer, presence, coordinator, Now Playing controller, position store, and book storage.

- [ ] **Step 5: Implement `CarPlayPlaybackCoordinator`.** Keep it `@MainActor`, inject the shared owner protocol, current user/generation provider, `ReaderViewModel` factory, and entitlement-gate closure. On a new selection:

1. Re-read the Keychain/current-user provider and reject a changed or missing account.
2. Return the existing-session toggle path when the selected ID is already active.
3. Gate narration before replacing an active session.
4. Create the reader VM with `BookFileStorage.absoluteFileURL(for:)` and the shared `positionStore`.
5. Await `vm.load()` and require a loaded publication.
6. Revalidate the captured user/generation after `vm.load()` and before handing the candidate to the owner.
7. Ask the owner to start the candidate with position callbacks and publish the active book ID only after success.

Do not stop the old controller until the replacement publication is loaded. On replacement failure, return an error result for the CarPlay alert and preserve the old session. On allowance failure, stop only the attempted session and return a user-facing result. Expose `pause`, `resume`, `toggle`, `next`, `previous`, and `stop` by forwarding to the explicit owner protocol, not by holding a second controller.

- [ ] **Step 6: Run owner/coordinator tests GREEN.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task3-green-derived \
  -only-testing:rishiTests/CarPlay/CarPlayPlaybackCoordinatorTests
```

Expected: all coordinator tests pass.

- [ ] **Step 7: Commit the playback slice.**

```bash
git add apps/apple/rishi/rishi/CarPlay/CarPlayPlaybackCoordinator.swift \
  apps/apple/rishi/rishiTests/CarPlay/CarPlayPlaybackCoordinatorTests.swift \
  apps/apple/rishi/rishi/Audio/ReadAloudPlaybackOwner.swift \
  apps/apple/rishi/rishi/Reader/ReaderDestination.swift \
  apps/apple/rishi/rishi/AppDependencies.swift \
  apps/apple/rishi/rishi/AppDependencies+Billing.swift \
  apps/apple/rishi/rishiTests/ReadAloudPlaybackOwnerTests.swift
git commit -m "feat: unify narration playback ownership"
```

### Task 4: Wire CarPlay templates and lifecycle

**Files:**
- Create: `apps/apple/rishi/rishi/CarPlay/CarPlaySessionCoordinator.swift`
- Create: `apps/apple/rishi/rishi/CarPlay/CarPlaySceneDelegate.swift`
- Create: `apps/apple/rishi/rishiTests/CarPlay/CarPlaySessionCoordinatorTests.swift`
- Modify: `apps/apple/rishi/rishi/rishiApp.swift` / `RishiAppDelegate` in the same file for `configurationForConnecting`

- [ ] **Step 1: Write failing session tests.** Test the state machine without requiring a live CarPlay simulator:

```swift
@Test("signed-out refresh installs a sign-in-on-iPhone state")
func signedOutState() async { /* assert no playable rows */ }

@Test("signed-in refresh builds continue-listening and library sections")
func signedInCatalogState() async { /* assert section titles and row IDs */ }

@Test("selection pushes shared Now Playing after playback starts")
func selectionPresentsNowPlaying() async { /* assert push callback */ }

@Test("disconnect removes observers and clears interface references")
func disconnectCleansUp() async { /* assert cleanup */ }
```

- [ ] **Step 2: Run session tests and confirm RED.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task4-red-derived \
  -only-testing:rishiTests/CarPlay/CarPlaySessionCoordinatorTests
```

Expected: compile/test failure because session/coordinator types do not exist.

- [ ] **Step 3: Implement the session coordinator.** Build only Apple system templates:

  - Root `CPListTemplate(title: "Rishi", sections: ...)`.
  - A `Continue Listening` section when rows exist.
  - A `Library` section when rows exist.
  - Disabled, concise status items for loading, signed out, and unavailable states.
  - `CPListItem` handlers that call the playback coordinator, invoke completion exactly once, refresh on failure, and present `CPAlertTemplate` for concise errors.
  - On successful selection, push `CPNowPlayingTemplate.shared` (never present it modally).

Refresh on connect and on reconnect. Compare the current Keychain user ID to the coordinator’s user ID before every selection; if it changed, stop/tear down the old CarPlay playback coordinator, rebuild the root state, and do not expose stale rows. Keep `CPInterfaceController` and notification tokens only for the current scene. On disconnect, remove observers and clear the interface reference but leave shared narration/audio running.

- [ ] **Step 4: Implement the scene configuration and delegate.** Behind `#if os(iOS) && canImport(CarPlay)`, add `RishiAppDelegate.application(_:configurationForConnecting:options:)`. For `CPTemplateApplicationSceneSessionRoleApplication`, return a configuration named `CarPlaySceneConfiguration`, set the scene class to `CPTemplateApplicationScene`, and set the module-qualified delegate class `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`; for the phone role return the existing generated `Default Configuration`. Conform `CarPlaySceneDelegate` to `CPTemplateApplicationSceneDelegate`. On `didConnect`, immediately set a loading root template, then:

```swift
let dependencies = AppDependencies.shared
if let userID = try? Keychain.load(.userId), let userID = UUID(uuidString: userID) {
    dependencies.setUserId(userID)
}
await dependencies.bootstrap()
// Construct CarPlaySessionCoordinator with dependencies.services and refresh.
```

Implement `didDisconnectInterfaceController` to perform session cleanup. Never use `UIApplication.shared` to find or manipulate the phone window, and never present authentication, subscription, or configuration UI in CarPlay.

- [ ] **Step 5: Run session tests GREEN and compile the CarPlay code.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-task4-green-derived \
  -only-testing:rishiTests/CarPlay/CarPlaySessionCoordinatorTests
```

Expected: all session tests pass and the iOS target compiles with `CarPlaySceneDelegate` included. Mac Catalyst compilation must continue to exclude every CarPlay source and test import through compile guards.

- [ ] **Step 6: Commit the scene/session slice.**

```bash
git add apps/apple/rishi/rishi/CarPlay/CarPlaySessionCoordinator.swift \
  apps/apple/rishi/rishi/CarPlay/CarPlaySceneDelegate.swift \
  apps/apple/rishi/rishiTests/CarPlay/CarPlaySessionCoordinatorTests.swift
git commit -m "feat: add CarPlay audio scene"
```

### Task 5: Audit Worker compatibility and verify the integrated feature

**Files:**
- Read/modify only if a concrete failing contract requires it: `workers/worker/src/audio-speech.test.ts`, `workers/worker/src/audio-speech-cache.test.ts`, `workers/worker/src/usage/api-usage-routes.test.ts`, and their existing production route/schema files.
- Test: Apple CarPlay test files and existing audio/read-aloud tests.

- [ ] **Step 1: Run the focused Worker contract tests with Bun.** From `workers/worker`, record explicit evidence for missing/invalid auth, consent denial, stream cancellation/provider abort, reservation settlement on cancellation, cache hit accounting, voice/speed forwarding, allowance errors, and append-only usage audit:

```bash
bun test src/audio-speech.test.ts src/audio-speech-cache.test.ts src/usage/api-usage-routes.test.ts
```

Expected: existing authenticated TTS stream, cache hit/miss, voice/speed forwarding, allowance enforcement, and usage accounting tests pass. Do not use raw SQL or modify Drizzle schema/migrations for this feature.

- [ ] **Step 2: Add a Worker regression test only if the audit reveals a missing CarPlay contract.** The test must first fail, then the smallest Drizzle/route-compatible implementation must make it pass. Do not add a CarPlay-specific endpoint when the existing stream already satisfies the contract.

- [ ] **Step 3: Run the full focused Apple suite.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-final-tests-derived \
  -only-testing:rishiTests/CarPlay \
  -only-testing:rishiTests/PackageTests/RishiAudio/RishiAudioTests \
  -only-testing:rishiTests/ReadAloudControllerTests
```

- [ ] **Step 4: Run the full Apple simulator build.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/rishi-carplay-final-build-derived
```

Expected: exit 0 and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Inspect artifacts and review the diff.** Verify the built iOS Info.plist contains the CarPlay scene role, the signed iOS product contains the CarPlay Audio entitlement, the Mac entitlement does not, and `git diff --check` is clean. Confirm no worker files changed if the contract audit passed without a gap.

Also verify that the built plist retains `UIWindowSceneSessionRoleApplication`, the CarPlay entry uses `CPTemplateApplicationScene` and `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`, and a device/archive embedded provisioning profile grants `com.apple.developer.carplay-audio`. Run an explicit Mac Catalyst compile and confirm all CarPlay source is excluded. Simulator success alone does not establish device provisioning approval. Manual acceptance must cover CarPlay reconnect and playback while the phone scene is locked/backgrounded; unit tests cannot prove the vehicle runtime.

- [ ] **Step 6: Commit any verified Worker change, if needed, and record the final implementation state.** Apple changes must remain under the allowed `apps/apple` paths; Worker changes must follow the repository’s Bun/Drizzle rules.

## Adversarial review loop

Each round must be independent: review the current artifact/code cold, log findings, update it, and re-review the updated artifact. Critical and High findings block advancement.

### Research review

Review the confirmed context and Apple/Worker assumptions before plan review. Check:

- the exact managed entitlement approved by the developer portal;
- iOS-only target guards and the shared-dependency launch path;
- the fact that CarPlay can connect before the SwiftUI phone scene;
- the existing Readium/TTS publication-loading seam;
- Worker auth, consent, cache, allowance, and cancellation behavior;
- account change/sign-out and stale catalog behavior.

Record the round in the plan with severity, evidence, and a concrete resolution. Re-review after every resolution until there are zero open Critical/High findings.

### Plan review

The independent plan reviewer must verify every requirement maps to a task, every behavioral change has a test location, every task order dependency is explicit, the plan does not promise unsupported chapter/UI behavior, the Worker scope is honest, and the signing/manifest checks are actionable. Append each review round below; do not replace prior rounds.

### Implementation review

After each implementation task, run a spec-compliance review and a code-quality review before starting the next task. After Task 5, run a final independent review against the whole diff. Re-check:

- provisioning/manifest correctness;
- one shared `AppDependencies` graph;
- no duplicate audio/Now Playing owners;
- stale-user and sign-out isolation;
- failed replacement playback preserving active playback;
- allowance/consent/error handling;
- disconnect/reconnect cleanup;
- iOS/Mac Catalyst guards;
- tests and build evidence;
- Worker source/schema/migration scope.

### Review record

The executor must append concrete tables here. A final PASS requires 0 open Critical/High findings, and no unresolved Medium findings unless explicitly accepted by the user.

#### Round 1 — research and plan review

| Severity | Finding and evidence | Resolution in this revision | Status |
|---|---|---|---|
| High | The phone creates a local `ReadAloudController`, while a CarPlay factory would create another; `NowPlayingController.attach` rejects duplicate ownership. | Added `ReadAloudPlaybackOwner`, migrated phone and CarPlay to host bindings, and added cross-host handoff tests. | Closed |
| High | PDF rows were planned even though the verified CarPlay path uses `ReaderViewModel` while the PDF reader has a separate model/path. | First release catalog is EPUB-only; PDF narration is explicit out of scope until an adapter is tested. | Closed |
| High | Sign-out/account switch could leave old-account audio active and allow in-flight stale catalog/playback results. | Add account generation, revalidate after every await, and stop/flush/dispose/detach before clearing identity. | Closed |
| High | A partial `UIApplicationSceneManifest` could remove the generated SwiftUI phone role. | Use `configurationForConnecting` only for the CarPlay role and preserve the generated `Default Configuration` fallback; verify both roles in the built plist. | Closed |
| High | Bare `CarPlaySceneDelegate` lookup may fail at runtime. | Require `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate` and artifact/runtime verification. | Closed |
| Important | Direct tests against final `ReadAloudController` methods were not fakeable and used an imprecise command surface. | Define an explicit MainActor owner protocol with exact CarPlay operations and inject a fake owner. | Closed |
| Important | Simulator signing/build evidence does not prove the approved device capability or background vehicle runtime. | Require embedded-profile/archive signing verification, Mac Catalyst compile, and manual locked-phone/reconnect acceptance. | Closed |

#### Round 2 — independent re-review

Two independent reviewers re-checked the updated design and plan. Both reported no open Critical or High findings. The remaining implementation risks are carried forward as explicit tests and artifact checks above; implementation may begin.

## Explicit out of scope

- Dashboard/navigation/instrument-cluster scenes.
- Voice chat or Siri media intents in this first CarPlay Audio implementation.
- Chapter selection, search, account management, subscriptions, and paywall presentation on CarPlay.
- Worker schema/migration changes when the existing authenticated TTS stream passes its focused tests.
