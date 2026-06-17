# Read Aloud player redesign

Date: 2026-06-17

## Goal

Improve the visual design and ergonomics of the Read Aloud (TTS) controls that
float over the reader. Move playback status out of a text label and into the
controls themselves, adopt native iOS 26 Liquid Glass, and surface errors via a
native alert instead of inline text.

## Scope (decided)

- **Form factor:** stays the floating compact glass bar pinned to the bottom of
  the reader. No album art, no scrubber, no full-screen now-playing screen.
- **Controls:** keep all six controls — previous-paragraph, repeat, play/pause,
  stop, next-paragraph, and the voice/speed settings picker — just restyled.
- **Status label:** removed entirely. Status is conveyed by the controls.
- **Errors:** surfaced via a new native `.alert`, not inline text.

Out of scope: progress scrubber, duration/elapsed UI, cover art, plumbing new
fields into `TTSPlaybackState`.

## Layout & ergonomics

A centered control cluster replaces today's left-aligned row. The play/pause
button is the visual anchor — larger, centered. Reading order:

```
[ prev  repeat  PLAY/PAUSE  stop  next ]            settings
            -- centered cluster --                   trailing
```

The settings/voice picker is separated from the transport cluster (trailing
edge) so it reads as secondary. Mac keeps the existing `macMaxWidth` cap so the
bar reads as a centered floating player rather than a full-window strip.

## Status moves into the play button

The status `Text` line (and its `tts-status` accessibility identifier) is
deleted. Status is expressed through the play/pause button:

- `.loading` -> the button shows an inline `ProgressView` spinner in place of
  the glyph and is disabled. No "Loading..." text.
- `.playing` / `.paused` -> conveyed by the `pause.fill` / `play.fill` glyph.
- `.idle` / `.stopped` -> `play.fill`.

**Accessibility-identifier contract (must be preserved):** the play/pause
button keeps id `tts-pause` while playing and `tts-play` while
idle/loading/paused. XCUITests (`ReadAloudNextParagraphUITests`,
`PDFReadAloudPageBoundaryUITests`) depend on this toggle: during loading the
button stays `tts-play` and disabled. The spinner is purely visual and does not
change the identifier. Other ids unchanged: `tts-stop`, `tts-prev-paragraph`,
`tts-repeat-paragraph`, `tts-next-paragraph`, `tts-open-picker`.

## Errors -> native alert (new work)

There is currently no native alert for TTS errors; `ReadAloudControlsView`'s
inline red text is the only surface for `state.error`. The existing
`VoiceFailureAlert` belongs to the separate voice-chat system and is not reused.

Add a small `TTSFailureAlert` helper (modeled on `VoiceFailureAlert`) and attach
a native `.alert` in the reader hosts (the reader destinations that embed
`ReadAloudControlsOverlay`). It is driven by `TTSPlaybackState.status == .error`
/ `state.error`, with a single "Dismiss" action that clears the error
(resets status away from `.error`). Because removing the inline label would
otherwise drop the only error surface, this alert is a precondition of the
label removal.

## Native Liquid Glass

Deployment target is iOS 18 (RishiAudio package supports iOS 17); all iOS 26
APIs stay gated behind `if #available(iOS 26.0, *)` with a material/plain
fallback, matching the existing `GlassCardBackground` pattern.

- The bar card remains the single glass surface (`GlassCardBackground` ->
  `.glassEffect(.regular, in:)` on iOS 26, `.regularMaterial` on iOS 18).
- The primary play/pause button gets a prominent/interactive native glass
  treatment on iOS 26 (e.g. `.glassEffect(.regular.interactive(), in: .circle)`
  or `.buttonStyle(.glassProminent)`), tinted with the accent color; on iOS 18
  it falls back to the current accent glyph.
- Avoid glass-on-glass nesting issues: secondary buttons stay plain glyph
  buttons over the card glass rather than each being its own glass blob. If a
  `GlassEffectContainer` is used it wraps the cluster so SwiftUI blends/morphs
  correctly. Final nesting choice resolved during implementation, biased toward
  HIG guidance ("don't make every button glass").

## Testing

- Swift Testing only. RishiAudio unit tests construct `ReadAloudControlsView`
  for every `TTSStatus` without crashing (existing) and continue to pass after
  the status-label removal.
- The error alert path is unit-tested where the helper is pure (title/message
  mapping, dismiss clears error), following `VoiceFailureAlert` test style.
- XCUITest identifier contract above is preserved; no UI test changes expected.
- Build gate: full `xcodebuild` for iPhone 17 simulator and Mac Catalyst, plus
  RishiAudio package tests, grepping for the literal BUILD/TEST SUCCEEDED
  marker.

## Constraints

- Commit only under allowed `apps/apple/` paths. No emojis. Stay on `main`.
- Do not flip default-isolation = MainActor. Do not replace AVFoundation/TTS
  engines — only the controls UI and a new alert helper change.
