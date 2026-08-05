# Catalyst EPUB Selection Menu Interaction Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status:** Implemented — compile regression corrected; adversarial reviews PASS; test execution remains partially environment-blocked.

**Goal:** Keep the Mac Catalyst EPUB selection menu dismissible with Escape while preserving click access to the reader’s left/right page arrows.

**Architecture:** Keep the existing full-screen dismissal catcher in `EPUBHighlightContextMenu`, because it is responsible for dismissing the menu when the user taps outside it. Render the edge-arrow controls after the menu and give them an explicit z-index so the arrows receive hits above the catcher. For Escape, use two platform-appropriate paths that call one idempotent callback: a Catalyst-only Readium `.key(.escape)` observer handles the case where the EPUB navigator owns focus, while a Catalyst-only SwiftUI `onKeyPress(.escape)` handles focus on the SwiftUI menu/buttons. The callback returns whether a selection existed, so Escape is not consumed when there is nothing to dismiss. iOS remains compilable because the Catalyst-only APIs are conditionally compiled.

**Tech Stack:** SwiftUI, Mac Catalyst, UIKit/Readium reader bridge, Swift Testing, Xcodebuild.

---

## Current evidence and constraints

- `ReaderScreen` currently renders the edge arrows at lines 213–231 and the selection menu afterward at lines 233–264. The later selection-menu sibling owns a full-screen hit-testable background, so it intercepts arrow taps.
- `EPUBHighlightContextMenu` wraps the content-sized `HighlightContextMenu` in a full-screen `GeometryReader` and adds a nearly transparent, hit-testable background at lines 43–62. That background intentionally dismisses the menu outside the buttons and must remain.
- Readium’s `Key` enum includes `.escape`, and the existing `ReaderNavigatorCoordinator` already registers `.key(.arrowLeft/.arrowRight)` observers on Catalyst. This gives the focused EPUB navigator a supported Escape interception point.
- `onExitCommand` is unavailable on the Catalyst/iOS availability domain and cannot be used for this target, even inside `#if targetEnvironment(macCatalyst)`. SwiftUI `onKeyPress(.escape)` is available from iOS 17/macOS 14 and is the compatible Catalyst fallback. The Apple source is compiled for both iOS and Catalyst.
- The existing Apple test suite uses source-level invariants for SwiftUI view-tree contracts because it does not render SwiftUI hit testing in unit tests. The new regression test follows that established pattern and uses an app-root resolver that finds `rishi.xcodeproj`, then appends `rishi/Modules/RishiReader/RishiReader/UI`.
- Preserve unrelated dirty worktree changes, including the Electron read-aloud changes and the untracked read-aloud design spec.

## File map

| File | Responsibility | Change |
|---|---|---|
| `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift` | Unified EPUB reader ZStack and edge navigation | Render the selection menu before the edge arrows, give the arrow layer an explicit higher z-index, and pass a selection-aware Escape callback into `ReaderView`. |
| `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/EPUBHighlightContextMenu.swift` | EPUB selection-menu positioning and dismissal | Add Catalyst-only `onKeyPress(.escape)` without removing outside-tap dismissal. |
| `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderView.swift` | UIKit representable callback bridge | Add and refresh an `onEscape` callback for the coordinator. |
| `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderNavigatorCoordinator.swift` | Readium navigator lifecycle and key policy | Add `handleEscape()` and a Catalyst `.key(.escape)` observer that returns the callback’s consumed status. |
| `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/UI/ReaderSelectionOverlayTests.swift` | Regression contracts for SwiftUI overlay ordering and Catalyst Escape wiring | Add source-level tests against the actual app-module paths. |
| `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/UI/ReaderEngineTapGestureWiringTests.swift` | Coordinator interaction tests | Test Escape callback consumption and non-consumption. |

## Consumer / call-site audit

| Consumer or producer | Current contract | Required preservation |
|---|---|---|
| `ReaderScreen` → `EPUBHighlightContextMenu` | `onDismiss` clears `pendingSelection` and calls `coordinator.clearSelection()` | Both Escape paths must invoke this same cleanup callback; no duplicate state-clearing implementation. |
| `ReaderScreen` → `ReaderView` | `onSelectionChange`, page callbacks, and tap callback are passed from SwiftUI state | Add `onEscape` and keep it current through both `makeUIViewController` and `updateUIViewController`. |
| `ReaderView` → `ReaderNavigatorCoordinator` | Coordinator owns the Readium navigator and key observers | Add `.escape` only under Catalyst; return `false` when no selection is pending so unrelated Escape behavior is not swallowed. |
| `ReaderScreen` → `EPUBEdgeArrowButton` | Buttons call `pageNavigator.goPrev()` / `goNext()` | Both buttons must remain visible and hit-testable while the menu is open. |
| `EPUBHighlightContextMenu` → `HighlightContextMenu` | Color/note actions remain content-sized and above its own background catcher | Menu buttons must continue to receive taps. |
| PDF reader path | Uses `PDFReaderScreen` and a different, content-sized menu arrangement | Do not alter PDF layout or dismissal semantics in this fix. |
| Electron reader path | Uses React/iframe selection popovers | Do not alter Electron files in this Apple-specific fix. |

## Implementation order

1. Add failing source-contract and coordinator tests.
2. Run the focused tests to confirm the red phase.
3. Implement arrow hit-testing order and both Catalyst Escape paths.
4. Run focused tests, neighboring reader tests, and the Catalyst build.
5. Perform an independent implementation review, address every finding, and re-review until the diff has no open Critical/High/Medium issues.

### Task 1: Add failing regression contracts

**Files:**
- Create: `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/UI/ReaderSelectionOverlayTests.swift`
- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/UI/ReaderEngineTapGestureWiringTests.swift`

- [x] **Step 1: Add a robust source resolver.**

In `ReaderSelectionOverlayTests.swift`, walk upward from `#filePath` until the first directory containing `rishi.xcodeproj`, then read:

```swift
let readerUIDir = appRoot
    .appendingPathComponent("rishi/Modules/RishiReader/RishiReader/UI", isDirectory: true)
```

Do not assume an absolute checkout path or a nonexistent `Sources/RishiReader` directory.

- [x] **Step 2: Add the arrow-order regression test.**

Read `ReaderScreen.swift`, find the first `if let pending = pendingSelection {` and the first `if ReaderEdgeArrowPolicy.shouldShow(`, and assert the pending-selection block appears first. Extract the substring from the arrow marker to the next `if let pending`/`#else` boundary and assert it contains `.zIndex(1)`. This fails against the current source and protects both ordering and explicit stacking.

- [x] **Step 3: Add Escape wiring source contracts.**

Read `EPUBHighlightContextMenu.swift`, `ReaderView.swift`, and `ReaderNavigatorCoordinator.swift`. Assert:

```swift
EPUBHighlightContextMenu.swift.contains("#if targetEnvironment(macCatalyst)")
EPUBHighlightContextMenu.swift.contains(".onKeyPress(.escape)")
EPUBHighlightContextMenu.swift.contains("KeyPress.Result.handled")
ReaderNavigatorCoordinator.swift.contains(".key(.escape)")
ReaderNavigatorCoordinator.swift.contains("public func handleEscape() -> Bool")
ReaderView.swift.contains("context.coordinator.onEscape = onEscape")
```

The source assertions must verify the Catalyst guard and the compatible `onKeyPress`/handled result; the unavailable `onExitCommand` API must not be present.

- [x] **Step 4: Add coordinator Escape behavior tests.**

In `ReaderEngineTapGestureWiringTests`, add these behavioral tests:

```swift
@Test("EPUB Escape invokes and consumes the selection dismissal callback")
func epubEscapeInvokesDismissalCallback() {
    var count = 0
    let coordinator = ReaderNavigatorCoordinator(viewModel: makeEPUBViewModel())
    coordinator.onEscape = { count += 1; return true }

    #expect(coordinator.handleEscape() == true)
    #expect(count == 1)
}

@Test("EPUB Escape can pass through when no selection is pending")
func epubEscapePassesThroughWithoutSelection() {
    let coordinator = ReaderNavigatorCoordinator(viewModel: makeEPUBViewModel())
    coordinator.onEscape = { false }

    #expect(coordinator.handleEscape() == false)
}
```

- [x] **Step 5: Run the focused tests in the red phase.**

Run from `apps/apple/rishi`:

```bash
xcodebuild test -project rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/ReaderSelectionOverlayTests -only-testing:rishiTests/ReaderEngineTapGestureWiringTests
```

Expected: the new tests fail to compile or assert because `onEscape`, `handleEscape`, `.key(.escape)`, the source paths/contracts, and the arrow ordering/z-index are not yet implemented.

### Task 2: Fix overlay ordering and Escape dismissal

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift:155-264`
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/EPUBHighlightContextMenu.swift:43-65`
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderView.swift:35-120`
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderNavigatorCoordinator.swift:60-145,427-445`

- [x] **Step 1: Expose a selection-aware Escape callback from `ReaderScreen`.**

Pass this callback into `ReaderView` alongside the existing page callbacks:

```swift
onEscape: {
    guard pendingSelection != nil else { return false }
    pendingSelection = nil
    coordinatorRef.coordinator?.clearSelection()
    return true
},
```

Keep the existing `EPUBHighlightContextMenu.onDismiss` cleanup identical. Both callbacks are idempotent: after the first one clears the selection, a second event returns `false` and does nothing.

- [x] **Step 2: Bridge and refresh `onEscape` in `ReaderView`.**

Add `public let onEscape: () -> Bool`, default it to `{ false }` in the initializer, assign it in `makeCoordinator` and `makeUIViewController`, and refresh it in `updateUIViewController` next to the existing callback refreshes:

```swift
context.coordinator.onEscape = onEscape
```

- [x] **Step 3: Add the coordinator Escape seam and Readium observer.**

Add:

```swift
public var onEscape: () -> Bool = { false }

@discardableResult
public func handleEscape() -> Bool {
    onEscape()
}
```

Inside the existing `#if targetEnvironment(macCatalyst)` observer registration, add:

```swift
_ = nav.addObserver(.key(.escape)) { [weak self] in
    self?.handleEscape() ?? false
}
```

This lets the focused Readium navigator dismiss the menu and preserves pass-through behavior when no selection is pending.

- [x] **Step 4: Add the SwiftUI Escape fallback only for Catalyst.**

After the existing `EPUBHighlightContextMenu` background modifier, add:

```swift
#if targetEnvironment(macCatalyst)
        .onKeyPress(.escape) {
            onDismiss()
            return KeyPress.Result.handled
        }
#endif
```

Do not compile this modifier for iOS.

- [x] **Step 5: Put arrows above the dismissal catcher.**

Move the complete `if let pending = pendingSelection` block before the `if ReaderEdgeArrowPolicy.shouldShow(...)` block in the `ReaderScreen` ZStack. On the arrow `HStack`, add:

```swift
.zIndex(1)
```

after `.allowsHitTesting(true)`. Do not add a full-width `contentShape` to the HStack; the empty middle must remain available for the menu’s outside-tap dismissal.

### Task 3: Verify the complete interaction contract

- [x] **Step 1: Run focused regression tests.**

```bash
xcodebuild test -project rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/ReaderSelectionOverlayTests -only-testing:rishiTests/ReaderEngineTapGestureWiringTests
```

Expected: all new source-contract and coordinator Escape tests pass.

- [ ] **Step 2: Run neighboring reader interaction tests.**

```bash
xcodebuild test -project rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/ReaderEngineTapGestureWiringTests -only-testing:rishiTests/ReaderTapToToggleWiringTests -only-testing:rishiTests/ReaderKeyboardNavigationPolicyTests
```

Expected: existing reader gesture, tap-routing, and keyboard-policy tests pass.

- [ ] **Step 3: Build the Catalyst target.**

```bash
xcodebuild build -project rishi.xcodeproj -scheme rishi -sdk maccatalyst -configuration Debug
```

Expected: exit code 0, including compilation of the Catalyst-only `onKeyPress(.escape)` and Readium Escape observer.

- [ ] **Step 4: Manually verify when a Catalyst runtime is available.**

Select text in an EPUB, click both edge arrows, and confirm each arrow navigates while the menu is open. Reopen the menu with the text view focused and press Escape; confirm the menu disappears and the selection clears. Repeat with focus on a menu button. Verify tapping a color/note button still invokes its existing action, and tapping the reader body still dismisses the menu without navigating. Confirm an Escape press with no selection is not swallowed by the new callback.

## Explicit out of scope

- No changes to Electron React/iframe selection popovers.
- No changes to PDF reader layout or PDF continuous-mode keyboard policy.
- No new global notifications, scene commands, or unrelated responder subclasses.
- No edits to unrelated dirty files or generated artifacts.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review. Implementation is gated on a PASS with zero open Critical/High/Medium issues.

### Implementation review — final round

| Reviewer | Scope | Finding | Resolution | Verdict |
|---|---|---|---|---|
| Independent reviewer 1 | Selection overlay and Escape diff | None | — | PASS |
| Independent reviewer 2 | Selection overlay and Escape diff | None; unrelated dirty page-command changes were explicitly excluded | Preserved unrelated worktree changes | PASS |
| Independent reviewer 3 | Final scoped review | None | — | PASS |

**Implementation review result:** PASS — 0 open Critical/High/Medium/Low issues in scope.

**Verification notes:** The iOS build phase compiled the changed reader sources. The focused test target was not executable because unrelated pre-existing voice/realtime test sources fail compilation. The Catalyst build was not executable because this Xcode installation has no `maccatalyst` SDK. Manual Catalyst verification remains pending until a Catalyst runtime is available.

### Round 1 — independent plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A scene-level keyboard-command fallback would not fix the reported click interception and would expand scope into active-window routing. | Replaced the fullscreen-command design with the direct Apple selection-overlay fix. |
| 2 | High | Adding Escape only to the shared button menu would not reliably receive Escape while the full-screen selection wrapper or Readium navigator owns focus. | Added a Readium `.key(.escape)` observer with a consumed-status callback, plus a SwiftUI fallback for Catalyst menu/button focus. |
| 3 | High | Removing the dismissal background entirely would fix arrow clicks but regress outside-tap dismissal. | The background catcher remains; only the arrow layer is moved above it. |
| 4 | Medium | A source-order-only test could pass while a later layout change still puts the arrows below the catcher. | The plan also requires `.zIndex(1)` on the arrow layer and tests both ordering and explicit z-index. |
| 5 | Medium | Unit tests cannot reliably exercise SwiftUI hit testing in the existing test environment. | Use source-level view-tree invariants, coordinator behavior tests, a Catalyst build gate, and manual runtime verification. |

**Round 1 result:** Critical/High findings resolved in the updated plan; re-review required.

### Round 2 — independent re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | `onExitCommand` is unavailable on iOS, but the first draft compiled it unconditionally in a `canImport(UIKit)` file. | The modifier is now explicitly wrapped in `#if targetEnvironment(macCatalyst)` and the plan retains an iOS simulator test/build gate. |
| 2 | High | The first draft’s test resolver used nonexistent `Sources/RishiReader/UI` paths. | The resolver now walks to `rishi.xcodeproj` and reads `rishi/Modules/RishiReader/RishiReader/UI`. |
| 3 | High | A SwiftUI `onExitCommand` alone may not receive Escape while Readium’s child navigator is first responder. | The plan now adds Readium’s supported `.key(.escape)` observer and tests the coordinator’s consumed/pass-through seam. |
| 4 | Medium | The first draft had no test for the empty middle of the arrow HStack remaining a dismissal surface. | The implementation explicitly forbids adding a full-width `contentShape`; manual verification includes body-tap dismissal while arrows remain active. |

**Round 2 result:** Critical/High/Medium findings resolved; re-review required against the updated plan.

### Round 3 — re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | — | Final independent review found no remaining Critical, High, or Medium issues. The Catalyst guard, actual module path, Readium Escape API, callback plumbing, and test commands match the current repository. | No change required. |

**Round 3 result:** PASS — 0 open Critical/High/Medium issues. Implementation may begin.

## Implementation review loop

After implementation, an independent reviewer must inspect the diff cold and verify the source-order, z-index, iOS-guard, Readium Escape, callback-refresh, and outside-tap contracts against the current files. Any Critical/High/Medium finding requires a code/plan update and a fresh review round. The final artifact must record PASS with zero open issues.

### Final implementation review

| Round | Scope | Finding | Resolution | Verdict |
|---|---|---|---|---|
| 1 | Selection overlay and Escape implementation | None in scope. A reviewer separately noted unrelated dirty page-command changes. | Preserved unrelated worktree changes; no scope expansion. | PASS |
| 2 | Final cold scoped review | None | No change required. | PASS |

**Implementation review result:** PASS — 0 open Critical/High/Medium/Low issues in scope.

**Verification notes:** The iOS test invocation compiled the changed reader sources, but the shared test target failed in unrelated pre-existing voice/realtime test files before executing the focused tests. The Catalyst build could not run because this Xcode installation does not provide the `maccatalyst` SDK. Manual Catalyst runtime verification remains pending until a Catalyst runtime is available.

### Post-implementation compile regression correction

The Catalyst screenshot exposed that the original `onExitCommand` guard was insufficient: SwiftUI declares that API `@available(iOS, unavailable)`, and Mac Catalyst uses the iOS/macabi availability domain. The regression contract was updated first to require no `onExitCommand` and to require `.onKeyPress(.escape)` returning `KeyPress.Result.handled`. The implementation then replaced only that fallback; the outside-tap catcher and Readium `.key(.escape)` path were unchanged.

Independent correction reviews: PASS with zero actionable findings. A clean elevated Catalyst build succeeded and compiled `EPUBHighlightContextMenu.swift`. The focused Catalyst test target remains blocked by the unrelated `PropertyBased` package’s `NSColor`-unavailable-for-Catalyst errors.
