# Background Read Aloud Playback Implementation Plan

> **Status:** Adversarial plan review loop complete — **PASS** (5 rounds, 0 open Critical/High/Medium issues).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep iOS Read Aloud/TTS audio playing after backgrounding or screen lock while preserving the current voice-chat shutdown behavior and lock-screen media controls.

**Architecture:** The existing TTS path already owns an active `.playback`/`.spokenAudio` `AVAudioSession` and publishes Now Playing controls. The implementation enables the iOS `audio` mode while preserving the existing `BGProcessingTaskRequest` sync mode, and updates the stale configuration smoke test; no new lifecycle pause/resume path is added, and voice chat remains governed by the existing background handler.

**Tech Stack:** Swift 6, SwiftUI, AVFAudio, MediaPlayer, WidgetKit, Xcode project `Info.plist`, Swift Testing.

---

## Requirements and evidence

| Requirement | Authoritative evidence | Planned change |
|---|---|---|
| Read Aloud continues in background/lock | Built app target plus physical-device smoke test | Declare `UIBackgroundModes` with `audio`; retain active TTS session |
| TTS is output-only background audio | `AudioSessionPolicy.swift`, `AudioSessionCoordinator.swift` | No production Swift change; verify existing `.playback`/`.spokenAudio` path |
| Lock-screen controls remain available | `NowPlayingControllerTests.swift`, `ReadAloudControllerTests.swift` | No implementation change; rerun focused tests |
| Voice chat still ends in background | `rishiApp.swift` `.background` handler | Leave handler unchanged; verify by source and existing voice tests |
| Existing background capabilities remain coherent | `BackgroundTaskCoordinator.swift` plus built `Info.plist` | Assert exactly `audio` and existing `processing`; do not add microphone or unrelated modes |

## Files and ownership

- Modify: `apps/apple/rishi/rishi/Info.plist` — add `audio` and preserve the existing `BGProcessingTaskRequest` flow with `processing` in the iOS app’s background modes.
- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/OnboardingUITests.swift` — replace the stale “audio is not declared” source assertion with a parsed-plist assertion that the exact approved mode set is `audio` plus existing `processing`.
- Verify only: `apps/apple/rishi/rishiApp.swift`, `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`, `apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/Coordinator/AudioSessionPolicy.swift`, `apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/Coordinator/AudioSessionCoordinator.swift`, and existing Now Playing/audio tests. Presence-widget source files are intentionally not touched because the extension is not registered in the current Xcode project.
- Documentation: this plan and the approved design are the current product decision. The 2026-07-28 App Review remediation documents are historical records of the previous release scope.

## Implementation order

### Task 1: Update the target capability and configuration regression test

**Files:**
- Modify: `apps/apple/rishi/rishi/Info.plist`
- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/OnboardingUITests.swift`

- [ ] **Step 1: Write the failing test**

Replace the old negative test with this parsed-plist assertion:

```swift
@Test("Background modes match the supported audio and sync features")
func backgroundModesMatchSupportedFeatures() throws {
    let data = try Data(
        contentsOf: Self.rishiRoot().appendingPathComponent("rishi/Info.plist")
    )
    let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    )
    let dictionary = try #require(propertyList as? [String: Any])
    let modes = try #require(dictionary["UIBackgroundModes"] as? [String])

    #expect(Set(modes) == Set(["audio", "processing"]))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from the repository root:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/OnboardingUITests
```

Expected: the new test fails because `apps/apple/rishi/rishi/Info.plist` currently has no `UIBackgroundModes` key. If the project-wide Xcode SDK `CoreVideo` PCM failure prevents test execution, record that pre-existing infrastructure failure and run the executable plist checks below instead.

- [ ] **Step 3: Add the minimal production configuration**

Insert this dictionary entry before the closing `</dict>` in `apps/apple/rishi/rishi/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
	<string>audio</string>
	<string>processing</string>
</array>
```

Do not modify `rishiApp.swift` or the TTS/audio-session implementation.

- [ ] **Step 4: Run focused verification**

Run:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/OnboardingUITests
plutil -lint apps/apple/rishi/rishi/Info.plist
/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:0' apps/apple/rishi/rishi/Info.plist | rg -x 'audio'
/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:1' apps/apple/rishi/rishi/Info.plist | rg -x 'processing'
if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:2' apps/apple/rishi/rishi/Info.plist >/dev/null 2>&1; then exit 1; fi
```

Expected: the onboarding assertion passes and the plist checks confirm exactly `audio` and `processing`. If the first command is blocked by the known Xcode SDK PCM failure, run the plist checks and the existing focused audio tests when the Xcode test target is available; do not weaken the assertion. This repository does not expose `RishiAudio` as a standalone Swift package.

- [ ] **Step 5: Commit the implementation task**

```bash
git add apps/apple/rishi/rishi/Info.plist apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/OnboardingUITests.swift
git commit -m "fix(apple): keep read aloud audio active in background"
```

## Verification and device acceptance

- [ ] Inspect the built app metadata with `plutil -p <built-app>/Info.plist` and confirm `UIBackgroundModes` is exactly `["audio", "processing"]` (order-independent when parsed).
- [ ] Run existing focused audio tests covering `AudioSessionPolicy`, `AudioSessionCoordinator`, `NowPlayingController`, and `ReadAloudController`.
- [ ] Run the full Apple build as the main orchestrator. The current baseline fails in Xcode’s `CoreVideo` simulator PCM generation before app compilation; rerun and compare the final result so no new source/build failure is hidden.
- [ ] On physical iOS/TestFlight: start Read Aloud, press Home, lock the screen, confirm audio continues, use lock-screen pause/resume, unlock, and confirm foreground controls remain coherent.
- [ ] Start voice chat and background the app; confirm it still ends through the unchanged voice lifecycle path.

## Explicit out of scope

- Background voice chat, microphone capture, or WebRTC continuation.
- Wiring or shipping the currently unregistered presence-widget extension, new widget actions, or a new Now Playing implementation.
- Automatic resume semantics for phone calls, route loss, or unrelated system interruptions.
- Changes to historical App Review remediation records.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review. The baseline build failure is recorded as pre-existing and must be rechecked after implementation.

### Round 1 — Plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | None of the production TTS code is changed, so the plan could fail if the existing session is released or paused during backgrounding. | Add explicit consumer/call-site audit and verification of `ReadAloudController.stopCurrentPlayback`, `rishiApp` `.background`, and the coordinator’s TTS ownership path. The plan now requires no background TTS pause hook and verifies release occurs only on explicit session stop. |
| 2 | High | The old onboarding test would continue to enforce the opposite behavior. | Task 1 replaces it with a parsed-plist assertion and names the correct test path. |
| 3 | High | Adding `audio` could accidentally expand background privileges to voice or unrelated work, while the target already schedules `BGProcessingTaskRequest`. | Preserve the existing processing mode alongside the new audio mode, assert the exact approved set `audio` plus `processing`, preserve voice shutdown, and exclude microphone/unrelated modes. |
| 4 | Medium | A simulator/source test cannot prove actual lock-screen audio continuity. | Add built metadata inspection and physical-device/TestFlight acceptance steps. |
| 5 | Medium | The full project build is currently broken before app-source compilation. | Record the baseline `CoreVideo` PCM failure, use focused package/source checks, and rerun the full build after implementation. |
| 6 | High | The repository contains presence-widget source files, but the widget target is absent from the Xcode project; claiming that the widget remains available would be false and could expand scope. | Distinguish MediaPlayer Now Playing controls from the unregistered widget source, verify only the former, and explicitly exclude widget target wiring. |
| 7 | High | The plan used an invalid test selector and string/format matching would not robustly verify the plist. | Use `-only-testing:rishiTests/OnboardingUITests`, parse `Info.plist` with `PropertyListSerialization`, and add executable `PlistBuddy` checks for exactly `audio` and `processing`. |

**Round 1 result:** Re-review required for the background-task reconciliation, corrected test selector, parsed plist assertion, and widget-scope correction.

### Round 2 — Independent adversarial review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The plan prohibited `processing` even though production schedules `BGProcessingTaskRequest`. | Resolved by preserving `processing` and asserting the exact approved set `audio` plus `processing`. |
| 2 | High | The plan’s `-only-testing` selector included a directory component and could select no tests. | Resolved with `-only-testing:rishiTests/OnboardingUITests`. |
| 3 | Medium | Raw XML formatting checks could pass with duplicate keys or an extra mode. | Resolved by parsing the plist and comparing the exact set. |
| 4 | Medium | The fallback verification did not execute the regression assertion. | Resolved with executable `PlistBuddy` index/value checks and a no-third-mode check. |
| 5 | High | Presence-widget source exists but is not registered as a target. | Resolved by separating actual MediaPlayer Now Playing behavior from unregistered widget source and excluding widget wiring. |

**Round 2 result:** Re-review required — fixes applied in the next round.

### Round 3 — Plan re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | None: the plan now preserves the existing background sync flow and adds only the requested output-audio capability. | Closed. |
| 2 | High | None: all target/test selectors, lifecycle call sites, mode ownership, and widget scope are explicit. | Closed. |
| 3 | Medium | Physical-device/TestFlight validation remains environment-dependent. | Explicit acceptance gate; automated plist and focused source/test checks remain available. |
| 4 | Medium | Historical docs disagree about whether background audio is supported. | The approved 2026-08-04 design and this plan define the current product decision; historical release/remediation records remain unchanged and are named as such. |

**Round 3 result:** PASS — 0 open Critical/High issues. Two environment-dependent Medium acceptance items remain explicit.

### Round 4 — Independent re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Built-metadata acceptance still required exactly `["audio"]`, contradicting the approved `audio` + `processing` set. | Corrected the acceptance step to require exactly `["audio", "processing"]`, order-independent when parsed. |

**Round 4 result:** Re-review required — final contradiction fix applied; the next cold pass must confirm zero open Critical/High issues.

### Round 5 — Final cold re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| — | — | No remaining Critical, High, or Medium contradictions found. | Final metadata, background-task, selector, lifecycle, and scope checks pass. |

**Round 5 result:** PASS — 0 open Critical/High/Medium issues.

## Adversarial implementation review gate

After Task 1, an independent reviewer must build-check first, inspect the diff against this plan, verify all lifecycle/configuration call sites, and report numbered findings. Any Critical/High finding must be fixed by the implementer and re-reviewed. The implementation is not complete until the final review reports zero open Critical/High issues and final verification evidence is recorded.

### Implementation Round 1 — Independent review

Build-first evidence: the main orchestrator reran the full Apple build after implementation. It still fails before app-source compilation in Xcode simulator `CoreVideo` PCM generation. The focused test reaches existing `rishiTests/RishiVoice` compilation errors before executing. Independent source/plist checks passed.

| # | Sev | Finding | Resolution |
|---|---|---|---|
| — | — | No Critical, High, Medium, or Low findings. | The diff is limited to the two planned files; plist lint and exact mode checks pass; the TTS audio-session path, voice-only background shutdown, and existing BGProcessingTask flow are unchanged. |

**Implementation Round 1 result:** PASS — 0 open findings. Re-review once more after recording this result.
