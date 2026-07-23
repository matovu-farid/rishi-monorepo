# Voice Controls Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve the reader voice-chat pill’s icon spacing, waveform centering, and transient status presentation without changing session behavior.

**Architecture:** Keep `VoiceSessionState` as the source of truth. Refactor `VoiceControlsView` into a fixed-height control row with 48-point button targets and a center overlay for the waveform. Add a view-local, generation-guarded transient toast for non-terminal statuses; persistent failure and ending-soon messages remain visible.

**Tech Stack:** Swift 6, SwiftUI, RishiUIKit tokens, Swift Testing.

---

### Task 1: Add behavior-focused UI test coverage

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceControlsViewTests.swift`

- [ ] **Step 1: Add a test for all phase/status combinations**

Use the existing construction tests and add a case that builds the view for transient statuses and persistent states, including `failed` and `isFinalInterval`, so the new presentation logic remains safe across every state.

- [ ] **Step 2: Run the focused UI tests and verify the baseline**

Run:

```bash
swift test --package-path apps/apple/Packages/RishiVoice --filter VoiceControlsViewTests
```

Expected: the existing tests pass before the layout implementation changes.

### Task 2: Refactor the control row geometry

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceControlsView.swift`

- [ ] **Step 1: Replace the variable-width center stack with a fixed center overlay**

Keep the left read-aloud button and right end/text-chat group in the row. Give every button a `48×48` frame and use the row’s overlay to place `VoiceWaveformView` at the geometric center, independent of the number or width of trailing controls.

```swift
ZStack {
    HStack(spacing: RishiSpacing.s) {
        readAloudButton
        Spacer(minLength: RishiSpacing.m)
        trailingButtons
    }

    VoiceWaveformView(phase: displayPhase)
        .frame(width: 56, height: 48)
}
.frame(maxWidth: .infinity, minHeight: 48)
```

- [ ] **Step 2: Apply consistent icon hit targets and internal padding**

Use a shared button-content helper or equivalent modifier so each SF Symbol has a 48-point hit target, remains centered, and preserves the existing accessibility identifiers and labels.

- [ ] **Step 3: Keep the row geometry stable while status text changes**

Remove the status `Text` from the center stack. The row must not measure or align against the variable status string.

### Task 3: Add transient status notification presentation

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceControlsView.swift`

- [ ] **Step 1: Add a generation-guarded toast state**

Store the current transient message and an integer generation in `@State`. On each connecting/listening/speaking/reconnecting change, replace the message, increment the generation, and schedule dismissal after roughly two seconds. A dismissal may clear the toast only when its captured generation is still current.

- [ ] **Step 2: Keep persistent states visible**

Failure text (`lastError` or “Couldn’t connect”) and “Ending soon” bypass automatic dismissal. Expose the toast as one accessibility status element and keep button accessibility unchanged.

- [ ] **Step 3: Animate the toast without changing the pill row layout**

Render the toast as an overlay above the fixed control row using a small capsule/background and a transition. Do not put it in the row’s `HStack` or center slot.

### Task 4: Verify and commit

**Files:**
- Modify: `apps/apple/docs/superpowers/specs/2026-07-23-voice-controls-layout-design.md` only if implementation details materially differ.

- [ ] **Step 1: Run focused UI tests**

```bash
swift test --package-path apps/apple/Packages/RishiVoice --filter VoiceControlsViewTests
```

Expected: all `VoiceControlsViewTests` pass.

- [ ] **Step 2: Run the complete RishiVoice package suite**

```bash
swift test --package-path apps/apple/Packages/RishiVoice
```

Expected: all package tests pass.

- [ ] **Step 3: Check formatting and commit the implementation**

```bash
git diff --check
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceControlsView.swift apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceControlsViewTests.swift
git commit -m "fix(voice): balance controls and transient status"
```
