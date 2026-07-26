# Mac Catalyst Screenshot Window Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch the Mac Catalyst app at 1440×900 logical points for reproducible 2880×1800 Retina screenshots.

**Architecture:** Add one Catalyst-gated SwiftUI `Scene.defaultSize(width:height:)` modifier to the existing `WindowGroup`. This preserves all current app lifecycle and view wiring, leaves iOS/iPadOS unchanged, and does not convert the size into a restrictive minimum.

**Tech Stack:** SwiftUI, Mac Catalyst, Xcode 16 project, `xcodebuild`.

---

## Files and responsibilities

- Modify `apps/apple/rishi/rishi/rishiApp.swift`: attach the Catalyst-only default scene size to the existing `WindowGroup`.
- Do not modify `PDFMacWindowSizing.swift`: its 440×480 minimum remains a separate readability constraint.

## Task 1: Add the Catalyst default scene size

**Files:**
- Modify: `apps/apple/rishi/rishi/rishiApp.swift:37-70`

- [x] Add a `#if targetEnvironment(macCatalyst)` block immediately after the existing `WindowGroup` content and before the scene lifecycle modifiers:

```swift
        #if targetEnvironment(macCatalyst)
            .defaultSize(width: 1440, height: 900)
        #endif
```

- [x] Keep the modifier on the `Scene` returned by `WindowGroup`, not on `RootView`, so the value controls the initial window rather than constraining app layout.

- [x] Preserve all existing `.onChange` and `.commands` modifiers and all unrelated working-tree edits.

## Task 2: Verify the change

- [x] Run the focused Catalyst build:

```bash
xcodebuild \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  build
```

Expected: exit code 0 and a completed `BUILD SUCCEEDED` result.

- [x] Inspect the diff and confirm only `rishiApp.swift` contains the implementation change; pre-existing user modifications remain untouched.

## Consumer / call-site audit

| Consumer | Current behavior | Required outcome |
|---|---|---|
| `rishiApp` `WindowGroup` | No explicit default size | Catalyst defaults to 1440×900 points |
| iPhone/iPad scenes | Same shared app declaration | No behavior change because the modifier is compile-time Catalyst-gated |
| `PDFMacWindowSizing` | Minimum 440×480 points when PDF reader appears | Remains unchanged and independent |
| App Store Connect screenshot workflow | Requires 1280×800, 1440×900, 2560×1600, or 2880×1800 pixels | 2× Catalyst capture can produce requested 2880×1800 pixels |

## Implementation order

1. Apply the single scene modifier.
2. Build the Catalyst target.
3. Run the independent implementation review and re-review after any fixes.

## Explicit out of scope

- Changing PDF reader minimum dimensions.
- Forcing or preventing window resizing.
- Changing iPhone/iPad launch sizes.
- Generating or uploading screenshots.
- Editing unrelated pre-existing worktree changes.

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The requested 2880×1800 value is a physical-pixel screenshot size, while SwiftUI scene sizing uses logical points. | Use 1440×900 logical points and document the required 2× capture surface. |
| 2 | Medium | Scene restoration may override a default size on subsequent launches. | Document this expected behavior and require resetting the restored window state before capture if needed. |
| 3 | Low | Reusing the PDF minimum-size helper would conflate a default with a restriction. | Keep the change in `rishiApp.swift`; leave `PDFMacWindowSizing.swift` unchanged. |

**Round 1 result:** High issue resolved in the plan; re-review required.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | — | No open Critical, High, or Medium issues found after checking the Catalyst SDK API and call-site audit. | No change required. |

**Round 2 result:** PASS — 0 open Critical/High/Medium issues.
