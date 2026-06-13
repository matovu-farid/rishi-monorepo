[Back to overview](../README.md)

# Read Aloud (Text-to-Speech)

## What it does

Read Aloud turns the page the reader is on into spoken audio. The user taps a speaker icon while reading a book, picks a voice and a speed, and the app streams synthesised speech from the worker, plays it through the device, and keeps the highlighted sentence in sync with the audio. It also wires into the iOS lock-screen "Now Playing" controls so the user can pause, skip, and resume from anywhere on the phone.

## The user flow

- Open a book in the reader and tap the Read Aloud button in the chrome.
- A small control bar appears with play/pause, voice picker, and speed slider.
- Audio streams in; the sentence currently being spoken is highlighted in the page text.
- The lock screen and AirPods controls work the same as music or a podcast.
- Tap stop, or close the book, and the audio session is released.

## Where it lives

| Role | File |
|------|------|
| Public entry point | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSEngine.swift` |
| Playback state (binds to SwiftUI) | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSPlaybackState.swift` |
| Controls UI | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/UI/ReadAloudControlsView.swift` |
| Voice + speed picker | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/UI/VoiceAndSpeedPicker.swift` |
| Network source (worker MP3 stream) | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSStreamer.swift` |
| MP3 → PCM decoder | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/MP3StreamDecoder.swift` |
| Lock-screen Now Playing | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/NowPlayingController.swift` |
| Sentence-highlight tracker | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSPassageTracker.swift` |
| Shared audio session owner | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/Coordinator/AudioSessionCoordinator.swift` |
| User settings (voice, speed) | `apps/apple/Packages/RishiAudio/Sources/RishiAudio/Settings/` |

## What it depends on

- `RishiCore` — shared types like `UserID`, error envelopes.
- `RishiAPI` — the `SpeechStreamEndpoint` and `WorkerClient` that actually fetch MP3 bytes from the worker.
- `RishiAuth` — to look up which user is signed in (the worker bills speech by user).
- `RishiUIKit` — colour, spacing, and typography tokens for the control bar.
- `RishiLogging` — structured event logs around start, stop, and stream errors.

## Why it's built this way

- `AudioSessionCoordinator` is a single shared actor that owns `AVAudioSession`. Voice Chat and TTS both need the system audio session, and if either reached in directly they would silently stomp the other. Routing through one coordinator means starting voice chat correctly tears down TTS, and vice versa.
- Audio is streamed and decoded chunk-by-chunk (`MP3StreamDecoder` → `AVAudioEngine`), not downloaded then played. This makes the first sentence start speaking within about a second instead of after the whole page renders to audio.
- The decoder, the streamer, and the engine are each separated behind small protocols, so tests can swap a fake chunk source (`FakeTTSChunkSource`) in without touching the network or `AVAudioEngine`.
- "One playback session at a time" is enforced inside `TTSEngine.start` — calling start again tears the previous session down. This avoids two overlapping voices.

## Gotchas

- The audio category is `.playback` with mode `.spokenAudio`. Do not change it locally; route everything through `AudioSessionCoordinator.requestActiveMode(.tts)`.
- TTS is a Pro feature. The UI surface checks the billing entitlement before showing the Read Aloud control.

---

**Next:** [billing.md](billing.md) — StoreKit, paywall, entitlements.
