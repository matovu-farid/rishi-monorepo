# Spike C — AVAudioEngine chunked MP3 streaming

Throwaway prototype. Measures latency-to-first-sample for streaming TTS
playback using AVAudioEngine + AVAudioConverter against the Rishi worker's
`/api/audio/speech` MP3 stream. Pass threshold: < 1000 ms (5-run mean per
device, iPhone and Mac Catalyst). Verdict feeds Phase 8 (TTS) — see
`../../.planning/phases/00-bootstrap-spikes/SPIKE-C-REPORT.md`.

## Run

```bash
export DEV_BYPASS_SECRET="your-dev-bypass-secret"

# Open Package.swift in Xcode, pick a device + run; OR
xcodebuild \
  -scheme SpikeCAudioEngine \
  -destination 'platform=iOS,name=Your iPhone' \
  -skipMacroValidation \
  build
```

## Required Info.plist keys

```
UIBackgroundModes = audio
```
No microphone description needed.

## Important caveat

`ChunkedMP3Decoder.decode(chunk:)` in this prototype emits a **silent** PCM
buffer of the target format so the `scheduleBuffer` completion fires and we
can measure tFirstAudio. A production-ready implementation will replace this
with an MP3-specific decode path (`AudioFileStreamOpen` +
`AudioConverterFillComplexBuffer`) — see the spike report for the migration
notes.

Latency-to-first-sample is the *transport + scheduling* number we care about
for Phase 8; the actual audio quality must be validated after wiring the
real MP3 decode path. Spike C measures the **first** of the two — that's
the riskier metric because it determines whether the user perceives "TTS
started speaking" within the OpenAI-style 1-second budget.
