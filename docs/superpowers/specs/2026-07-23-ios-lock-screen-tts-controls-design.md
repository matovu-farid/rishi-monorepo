# iOS lock-screen TTS controls design

## Scope

When Read Aloud is active on iOS, the Lock Screen and Control Center must show
the current book and let the listener control narration after locking the
device or placing the app in the background. The system surface must stay in
sync with the in-reader transport controls and must disappear when the
read-aloud session ends.

This work uses the existing `MPNowPlayingInfoCenter` and
`MPRemoteCommandCenter` adapters. It does not introduce a custom lock-screen
UI or a second audio pipeline.

## Current integration point

The audio graph already creates the production MediaPlayer surfaces in
`apps/apple/rishi/rishi/AudioStackFactory.swift` and exposes their
`NowPlayingController` as `BootstrappedServices.nowPlayingController`. The app
also already declares the `audio` background mode and configures the TTS audio
session as `.playback` / `.spokenAudio`.

The missing link is the session owner. `ReaderDestination` creates a
`ReadAloudController`, but neither creation path passes the now-playing
controller to it, and `NowPlayingController.attach` / `detach` have no call
sites. `ReadAloudController` is therefore the sole lifecycle owner for the
system media surface: inject the dependency there and attach/detach it as part
of each reader session.

The implementation must not attach the now-playing controller directly to the
raw `TTSPlaying` engine. The shipping engine is
`ChunkedAudioPlayerTTSEngine`, while the existing `TTSPlaybackControlling`
conformance applies only to the older `TTSEngine`; the existing skip and scrub
methods are no-ops. A reader-level remote-command adapter is required.

## Command mapping

The system offers its own control layout, so it will be equivalent to—not an
exact copy of—the reader control bar. Register only commands whose result is
unambiguous for paragraph narration:

| System command | Reader action | Availability |
| --- | --- | --- |
| Play | resume the active read-aloud session | paused |
| Pause | pause the active read-aloud session | playing or loading after playback begins |
| Toggle play/pause | select play or pause from the current state | active session |
| Previous track | `ReadAloudController.previous()` | active session |
| Next track | `ReadAloudController.next()` | active session |
| Stop | `ReadAloudController.stop()` | active session; the system may choose not to display it |

Use `previousTrackCommand` and `nextTrackCommand`, not 15-second skip
commands: a paragraph has no reliable time-based position, and track controls
communicate discrete navigation better. Disable skip-forward, skip-backward,
and `changePlaybackPositionCommand`. Do not advertise a seekable timeline.

`repeatCurrent`, voice-chat handoff, and the voice/speed picker have no
appropriate standard lock-screen command and remain in the in-app controls.
The remote adapter must route commands to `ReadAloudController`, preserving
Readium's paragraph navigation and audio-session coordination rather than
bypassing them through the audio player.

## Metadata and playback state

At session attachment, publish:

- book title as the now-playing title;
- book author as the artist when present;
- cached cover data as artwork when it can be read without delaying playback;
- audiobook media type, so the system classifies narration appropriately;
- playback rate of `1.0` while playing and `0.0` while paused.

Cover artwork is best effort. Read `BookFileStorage.cachedCoverURLIfFresh(for:)`
first and omit artwork if no fresh file is already available; do not extract a
cover or block narration merely to populate the Lock Screen. Session metadata
must be prepared before attach so a new book cannot inherit a prior book's
artwork or author.

Do not set a duration estimate or elapsed-time/progress metadata in this
iteration. `TTSPlaybackState.elapsed` is not advanced by the shipping
`ChunkedAudioPlayerTTSEngine`, so publishing it would create a misleading
scrubber. The existing state observer remains responsible for playback-rate
updates only until actual passage timing is available.

## Lifecycle

1. Start a reader session: end any prior now-playing attachment, build the
   book metadata, attach the now-playing controller to the shared
   `TTSPlaybackState` and reader-level remote adapter, then start narration.
2. Pause, resume, next, and previous: retain the attachment and allow the
   shared playback state to update the displayed play/pause state.
3. Stop, natural end, playback failure, reader navigation that stops
   narration, voice-session preemption, and reader teardown: detach exactly
   once. Detach unregisters remote targets and clears `nowPlayingInfo`.
4. Start another book/session: detach the prior attachment before registering
   the next one. This is required because repeated MediaPlayer target
   registration can invoke a command more than once.

Locking the device and backgrounding the app do not end a reader session; the
existing audio background mode keeps the playback session eligible to continue.
Force-quitting from the app switcher terminates the process, so continued audio
and usable media controls are explicitly out of scope.

## Non-goals and limitations

- The app cannot control which individual buttons iOS presents on every Lock
  Screen, Control Center, headset, car, or external-route UI; iOS selects the
  visible subset.
- There is no seek bar, chapter timeline, playback speed control, or remote
  repeat-current command in this release.
- No playback recovery is promised after process termination.
- macOS and Mac Catalyst retain their existing behavior; iOS is the target
  surface for this change.

## Tests and acceptance checks

Extend the existing MediaPlayer fakes and `NowPlayingController` package tests
to cover previous-track, next-track, stop, disabled seek/skip commands, and
rate changes. Update `ReadAloudController` app tests to inject fake
now-playing surfaces/adapter and assert:

- one attachment with the expected title and author at session start;
- simulated play, pause, previous, next, and stop commands call the matching
  reader behavior;
- stop, natural completion, error, voice preemption, navigation teardown, and
  a replacement session detach and clear metadata exactly once;
- a replacement session does not retain previous artwork or duplicate targets.

Perform a manual iPhone verification with a real EPUB and PDF: start Read
Aloud, lock the device, use play/pause and previous/next from Lock Screen and
Control Center, background and foreground the app, test headphone controls,
then stop narration and confirm the system surface clears. Also verify an
audio interruption and the voice-chat handoff do not leave stale controls.
