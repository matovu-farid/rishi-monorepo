# Voice Character Position Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the voice character occupy a native-aspect-ratio slot matching the supplied `138×179` artwork composition.

**Architecture:** Keep `VoiceCharacterView` and its existing layered animation unchanged. Define the character slot size once in `VoiceSessionView` using the existing `canvasAspectRatio`, apply that size to the character, and expose the size as an internal testable constant so the layout contract is regression-tested.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Swift Package Manager.

---

### Task 1: Replace the square character slot with a native-aspect-ratio slot

**Files:**
- Modify: `Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift`
- Test: `Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift`

- [ ] **Step 1: Add a failing layout-contract test**

Add this test after the existing `VoiceCharacterView` tests in `VoiceUISnapshotTests`:

```swift
@Test("VoiceSessionView gives the character a native-aspect-ratio slot")
func sessionViewCharacterSlotPreservesAspectRatio() {
    let slot = VoiceSessionView.characterSlotSize

    #expect(slot.height == 160)
    #expect(abs(slot.width - (slot.height * VoiceCharacterView.canvasAspectRatio)) < 0.001)
    #expect(abs((slot.width / slot.height) - VoiceCharacterView.canvasAspectRatio) < 0.001)
}
```

- [ ] **Step 2: Run the focused test and verify the contract is missing**

Run:

```bash
swift test --package-path Packages/RishiVoice --filter VoiceUISnapshotTests/sessionViewCharacterSlotPreservesAspectRatio
```

Expected: compilation fails because `VoiceSessionView.characterSlotSize` does not exist yet.

- [ ] **Step 3: Add the shared character slot constant**

In `VoiceSessionView`, add this internal static property near the existing public accessibility identifier:

```swift
static let characterSlotSize = CGSize(
    width: 160 * VoiceCharacterView.canvasAspectRatio,
    height: 160
)
```

Replace the current fixed square frame:

```swift
.frame(width: 160, height: 160)
```

with:

```swift
.frame(width: Self.characterSlotSize.width, height: Self.characterSlotSize.height)
```

Leave the `VoiceCharacterView` aspect-ratio modifier, status layout, transcript reservation, End button, accessibility modifiers, and waveform fallback unchanged.

- [ ] **Step 4: Run the focused UI tests**

Run:

```bash
swift test --package-path Packages/RishiVoice --filter VoiceUISnapshotTests
```

Expected: the package either executes the UI suite successfully or stops at the repository’s already-documented `StubEphemeralKeyFetcher` baseline compilation issue. If it stops at that baseline issue, run the package build command and record the exact output without changing unrelated code.

- [ ] **Step 5: Inspect the diff for scope and whitespace regressions**

Run:

```bash
git diff -- Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift
git diff --check
```

Expected: only the character slot constant, its frame usage, and the focused test are changed; `git diff --check` emits no errors.

- [ ] **Step 6: Commit the implementation**

```bash
git add Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift
git commit -m "fix: preserve voice character aspect ratio"
```

Do not stage or modify the user’s existing `VoiceCharacterView.swift`, test changes, `character.svg`, or `.superpowers` companion files as part of this commit.

### Task 2: Verify the final implementation

**Files:**
- Verify: `Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift`
- Verify: `Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift`

- [ ] **Step 1: Run the complete RishiVoice package tests**

```bash
swift test --package-path Packages/RishiVoice
```

- [ ] **Step 2: Confirm the final diff is limited to the approved scope**

```bash
git status --short
git diff HEAD~1 --stat
git diff HEAD~1 --check
```

Confirm that the implementation commit contains only the two approved Swift files and that unrelated pre-existing changes remain unstaged.
