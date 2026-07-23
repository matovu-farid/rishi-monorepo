# Voice Activation PCM Handoff — Design Spec

**Date:** 2026-07-23  
**Plan:** [`2026-07-23-voice-activation-pcm-handoff.md`](../plans/2026-07-23-voice-activation-pcm-handoff.md)

## Goal

Capture user speech during the 1–3 s WebRTC connect window via a local `AVAudioEngine` recorder, then replay it into the OpenAI Realtime session over the `oai-events` data channel before enabling live RTP mic capture.

## Architecture

1. **Presenter** owns `VoiceActivationCoordinator`; calls `beginActivation()` after `requestActiveMode(.voice)` (skipped on park/resume).
2. **Session** connects with `deferMicCapture: true` (skips `enableAudioUnit()`).
3. **Handoff** runs after trial register-call (or legacy connect), before `.live`.
4. **Inject** buffered PCM via Path 0A (`conversation.item.create` + `input_audio`), with Path 0B (`append` + `commit`) fallback in adapter.
5. **Plan C:** Speech transcript → text turn if PCM inject fails.
6. **Live mic:** `setMicCaptureEnabled(true)` after inject completes.

## OpenAI audio input (research summary)

| Path | Mechanism | Use |
|------|-----------|-----|
| Live RTP | `LKRTCAudioTrack` + `enableAudioUnit()` | Post-handoff turns |
| 0A | `conversation.item.create` + `input_audio` | Primary buffered inject |
| 0B | `input_audio_buffer.append` + `commit` | Adapter fallback |
| 0C | `conversation.item.create` + `input_text` | Speech transcript fallback |

Payload format: **PCM16 LE, 24 kHz, mono, base64** (matches `RealtimeSessionConfigBuilder`).

## Task 0 spike status

**Not run against live OpenAI.** Task 0 is a required gate for this design; the implementation proceeded without recording its outcome. Do not treat 0A, 0B, or 0C as a working fallback chain.

## Implementation audit — 2026-07-23

**Status: REMEDIATED (Task 0 live spike still pending).** P0 gaps from the audit below are addressed in code; live OpenAI transport verification remains a manual gate.

| Severity | Finding | Resolution |
|---|---|---|
| P0 | `beginActivation()` awaited Speech auth before recorder | Recorder starts immediately; Speech attaches best-effort in background |
| P0 | `EnergyVADMonitor.stop()` cleared `everSpoke` before handoff read | `everSpoke` preserved; handoff reads before stop |
| P0 | Speech start failure cancelled activation | Falls back to Energy VAD; recorder keeps running |
| P1 | 0A/0B chosen by size only | 0A first; explicit rejection triggers 0B; timeout → ambiguous |
| P1 | SpeechVAD wait continuation race | Continuation install + signal under lock |

Task 0 live spike outcome: **not yet recorded** — do not treat production inject paths as verified against OpenAI until spike completes.

## Module layout

`RishiVoice/Activation/` — `VoiceActivationCoordinator`, `ActivationAudioRecorder`, `SpeechVADMonitor`, `EnergyVADMonitor`, `PCM24kConverter`.

## Edge cases

See plan § Edge cases. Park/resume skips activation. Reconnect uses default `deferMicCapture: false`.
