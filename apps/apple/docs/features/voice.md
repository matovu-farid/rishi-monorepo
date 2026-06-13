# Voice Chat

[Back to contributor README](../README.md)

## What it does

Voice chat is the live, talk-out-loud version of text chat. The user
taps the microphone button, grants permission, and a real-time voice
call opens to the assistant. The user speaks; the assistant speaks back;
both sides of the transcript are captured and merged into the same
conversation log that text chat uses. Audio flows over WebRTC, a
peer-to-peer real-time media protocol used by browsers for video calls.

## The user flow

- From the reader or the chat panel, tap the voice button.
- The first time, iOS asks for microphone permission. If denied, the
  user sees an explanation with a button into Settings.
- A status badge shows "connecting", then "live". A waveform appears.
- The user talks; the assistant responds with voice; the transcript
  appears underneath in real time.
- Tap end. The session shuts down and the transcript is saved as a new
  chat conversation tied to the current book.

## Where it lives

| Role | File |
| --- | --- |
| Entry point view | `Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift` |
| Permission prompt | `Packages/RishiVoice/Sources/RishiVoice/UI/VoicePermissionPrompt.swift` |
| Session lifecycle (actor) | `Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift` |
| Observable session state | `Packages/RishiVoice/Sources/RishiVoice/State/` |
| Ephemeral key fetcher | `Packages/RishiVoice/Sources/RishiVoice/Service/EphemeralKeyFetcher.swift` |
| Realtime client adapter | `Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift` |
| Transcript bridge | `Packages/RishiVoice/Sources/RishiVoice/Service/VoiceTranscriptBridge.swift` |
| Mic permission gate | `Packages/RishiVoice/Sources/RishiVoice/Permissions/` |
| Persistence | `MessageStore` from `RishiDB`, via the transcript bridge |

## What it depends on

- `RishiCore` — message and conversation types.
- `RishiAPI` — `WorkerClient` to fetch the ephemeral session key from
  `/api/realtime/client_secrets`.
- `RishiAudio` — `AudioSessionCoordinator`, which owns the
  AVAudioSession mode and arbitrates between TTS and voice.
- `swift-realtime-openai` (third-party, pinned to a specific commit
  from Spike B in Phase 0). It wraps WebRTC and the OpenAI Realtime
  API.

## Why it's built this way

- The session is an actor running an explicit state machine (`idle →
  requestingMic → fetchingKey → connecting → live → reconnecting →
  ended`, with `failed(reason)` from any state). Dropped Wi-Fi and
  revoked permissions are common; the explicit FSM handles both.
- The session never imports CallKit. That is a hard contract
  (VOICE-08) so the user cannot accidentally trigger phone-call UI.
- The session acquires the `.voice` audio mode *before* handing the
  ephemeral key to the realtime client and releases it on every exit
  path — including failure. That guarantee stops voice from stranding
  the audio session and silencing TTS later.
- The ephemeral key has a short lifetime; the worker mints a fresh one
  per session. The client never sees the long-lived API key.
- Reconnects use 1s, 2s, 4s exponential backoff over three attempts
  per the Spike B report from Phase 0.

## Gotchas

- The microphone permission prompt is one-shot. If denied, the user
  must re-enable from Settings. `VoicePermissionPrompt` detects that
  case and links into the app's Settings page.
- The transcript merges into the same `MessageStore` as text chat, so
  a single conversation can mix voice and text messages.

---

**Next:** [audio-tts.md](audio-tts.md) — text-to-speech read-aloud.
