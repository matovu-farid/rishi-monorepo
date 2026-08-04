# Background Read Aloud Playback Design

> **Status:** Approved by the user on 2026-08-04. Read Aloud/TTS should continue when the app is backgrounded or the device is locked; voice chat should retain its current background shutdown behavior.

## Goal

Make iOS Read Aloud behave like a media player: narration continues after Home/background and screen lock, while the existing lock-screen Now Playing controls and remote commands remain available. The repository also contains presence-widget source files, but that extension is not currently wired into the Xcode target; widget shipping is not part of this fix.

## Current evidence and root cause

The TTS stack already configures `AVAudioSession` as `.playback` with `.spokenAudio`, activates it before Readium starts, and attaches `NowPlayingController` before the first utterance. The app lifecycle handler only ends the voice session when the scene enters `.background`; it does not stop Read Aloud. However, the app target currently declares no `UIBackgroundModes` entry, so iOS is not authorized to keep the output audio session alive after backgrounding or locking.

The existing `OnboardingUITests.audioIsNotABackgroundMode` test encodes the former App Review remediation decision and must be changed because the requested product behavior has changed. Historical remediation documents remain historical records; this design supersedes their previous “background playback out of scope” decision.

## Design

1. Add `UIBackgroundModes` with the two values `audio` and `processing` to the iOS app’s `Info.plist`. `audio` enables persistent Read Aloud output; `processing` preserves the already-implemented `BGProcessingTaskRequest` sync flow.
2. Keep the existing TTS audio ownership path unchanged: `AudioSessionPolicy` selects `.playback`/`.spokenAudio`, `AudioSessionCoordinator` activates the session, and `ReadAloudController` releases it only when the read-aloud session actually stops.
3. Do not add a scene-phase pause/resume hook for TTS. Backgrounding and locking are lifecycle transitions, not user pause actions; adding a pause hook would recreate the bug and would also interfere with the existing voice-only shutdown path.
4. Keep the voice background shutdown in `rishiApp.swift` unchanged.
5. Update the configuration smoke test to parse the plist and assert that the target declares exactly the two already-supported modes, `audio` and `processing`. The existing Now Playing and remote-command tests remain the behavioral coverage for lock-screen controls.

## Data flow

```text
Read Aloud starts
  -> AudioSessionCoordinator configures .playback/.spokenAudio
  -> AVAudioSession becomes active
  -> ReadAloudController attaches Now Playing metadata and commands
  -> iOS scene backgrounds or screen locks
  -> UIBackgroundModes=audio permits the active output session to continue
  -> TTS engine continues; Now Playing remains controllable
```

Voice chat remains separate:

```text
scenePhase = .background
  -> rishiApp asks VoiceSessionPresenter to requestEnd()
  -> voice chat ends as before
```

## Error handling and constraints

- No new runtime fallback is needed: if audio-session configuration fails, the existing coordinator logs the failure and the existing foreground behavior remains unchanged.
- Do not add `microphone` or unrelated background modes. Keep `processing` because the target already registers and schedules `BGProcessingTaskRequest` for sync.
- Do not change the audio engine, Readium, Now Playing implementation, widget storage, or voice lifecycle.
- The user-visible device test must use a physical iOS device or a simulator configuration that supports background audio; a source-level plist assertion alone cannot prove uninterrupted playback.

## Verification

- Run the focused Swift Testing suite covering the changed onboarding/configuration assertion and existing audio-session/Now Playing tests.
- Build the Apple target with `xcodebuild` and inspect the built app’s `Info.plist` to confirm `UIBackgroundModes` contains exactly `audio` and `processing`.
- On device/TestFlight, start Read Aloud, press Home, lock the screen, and verify narration continues and the lock-screen Now Playing pause/resume commands work.
- Verify voice chat still ends when the app enters the background.

## Out of scope

- Background voice chat or microphone capture.
- Wiring or shipping the currently unregistered presence-widget extension, new widget actions, or a new Now Playing implementation.
- Automatic resume after unrelated audio interruptions; existing interruption semantics are unchanged.
