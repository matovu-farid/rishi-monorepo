# Voice Session Parking and Lifecycle Cleanup

## Goal

When the user ends voice chat, keep the existing realtime connection briefly available for fast resume while making it unable to capture microphone audio or play assistant audio. Close it after three minutes of inactivity, close immediately when the app backgrounds, and recover orphaned server sessions on the next launch after a crash or force-quit.

## Behavior

- Explicit End parks the active `RealtimeVoiceSession`.
- Parking cancels any in-flight response, disables local microphone capture, disables assistant playout, stops reconnect observation, and hides voice UI.
- The WebRTC/session object remains retained for up to three minutes.
- Reopening voice before expiry unmutes the transport, resumes reconnect observation, and returns the session to `.live` without creating a new server session.
- Expiry performs full local teardown and delivers the server-side `end` operation.
- App backgrounding performs full teardown immediately; it never uses the grace period.
- A crash cannot run cleanup code. The registry persists the server session ID and performs best-effort cleanup on next launch before a new voice session may start.

## Architecture

`VoiceSessionRegistry` is the app-lifetime owner for the active voice session reference, lifecycle state, and persisted server-session ID. `VoiceSessionPresenter` remains the UI-facing façade and delegates park/resume/close operations to the registry. `RealtimeVoiceSession` owns transport-level park/resume semantics. `RealtimeAPIAdapter` exposes explicit mute, output-gate, response-cancel, and disconnect behavior.

The existing `/api/voice-sessions/end-active` call remains a recovery aid, but cleanup must also use the persisted `/:id/end` path because the endpoint may be unavailable in an older deployment. IDs are cleared only after confirmed terminal server responses.

## Lifecycle State

```text
live --End--> parked --resume--> live
parked --3 min idle--> closing --> ended
live --background--> closing --> ended
launch --persisted id--> recovery cleanup --> ready
```

## Safety Invariants

1. A parked session cannot capture microphone audio or emit assistant audio.
2. A parked session cannot schedule reconnect work.
3. Only one close/expiry operation may run at a time.
4. Resume cancels the expiry timer before enabling audio.
5. Server session IDs remain persisted until the server confirms closure.
6. App lifecycle close is idempotent and safe when no session exists.

## Testing

- Adapter tests verify mute/unmute, assistant output gating, response cancellation, and idempotent disconnect.
- Session tests verify park/resume transport state and reconnect cancellation/restart.
- Registry/presenter tests verify timer reset, expiry, background close, single-flight close, and persisted orphan recovery.
- Existing RishiVoice package and iOS app build/test targets remain green.
