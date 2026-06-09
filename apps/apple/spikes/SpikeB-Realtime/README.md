# Spike B — swift-realtime-openai 30-min voice session

Throwaway prototype. Validates whether `m1guelpf/swift-realtime-openai` can
hold a 30-minute WebRTC voice session against the Rishi worker's ephemeral-key
endpoint with VAD + tool-call parity to the electron client. Verdict feeds
Phase 10 (Real-Time Voice Chat) — see
`../../.planning/phases/00-bootstrap-spikes/SPIKE-B-REPORT.md`.

This package is **not** part of the `rishi` app target.

## Run

```bash
# 1. Set the dev bypass secret (per reference_dev_bypass.md).
export DEV_BYPASS_SECRET="your-dev-bypass-secret"

# 2. Build for the desired platform via Xcode:
#    open Package.swift, pick a device + run.
#
# Or via xcodebuild:
xcodebuild \
  -scheme SpikeBRealtime \
  -destination 'platform=iOS,name=Your iPhone' \
  -skipMacroValidation \
  build

# 3. Run on a real iPhone (NOT simulator — WebRTC mic input is unreliable in
#    the simulator) and on Mac Catalyst. Start a session, speak intermittently
#    for 30 wall-clock minutes. Filter Console.app for "[SpikeB]" to capture
#    the event timeline. Bring up Instruments → os_signpost to view the
#    voice-session interval.
```

## Required Info.plist keys (set in Xcode target settings)

```
NSMicrophoneUsageDescription = "Spike B uses your microphone to test a 30-minute voice session with OpenAI Realtime."
UIBackgroundModes = audio
```

When wrapping with an explicit Xcode project, also enable:
- Capability **Background Modes → Audio, AirPlay, and Picture in Picture**
- Capability **App Sandbox → Audio Input** (Catalyst)

## What the harness validates

1. **Worker handshake.** `GET https://api.fidexa.org/api/realtime/client_secrets?language=en`
   with `X-Dev-Bypass` header. Returns ephemeral client secret.
2. **WebRTC session.** Connects via `Conversation.connect(ephemeralKey:)` with
   electron-parity VAD config (threshold 0.7, silence 700 ms, prefix
   padding 300 ms) and voice=alloy.
3. **Tool-call serialization.** Declares an `endConversation` tool definition.
4. **Audio session resilience.** Observes `AVAudioSession.routeChangeNotification`
   and `interruptionNotification`. Phone-call interruption recovery is the
   target use case.
5. **Sustained run.** Elapsed timer + disconnect counter. Target ≥ 30 minutes
   without unrecovered disconnect.
