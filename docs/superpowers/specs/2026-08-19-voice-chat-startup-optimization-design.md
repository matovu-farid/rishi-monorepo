# Voice Chat Startup Optimization Design

> **Status:** Research-complete design for the implementation plan

## Goal

Reduce the time from tapping Voice Chat to usable realtime transport while
preserving the current direct iOS → OpenAI WebRTC media path, Worker admission
and allowance guarantees, transcript buffering, and the single-session
invariant.

The startup path currently performs local permission/audio work, Worker
admission, OpenAI ephemeral-key minting, SDP/WebRTC negotiation, data-channel
startup, and local conversation setup. The critical-path improvements in this
design remove avoidable serialization and prevent work that cannot succeed
from reaching the network.

## Current critical path

1. `VoiceSessionPresenter.start` performs stale-session cleanup and checks
   consent/user state.
2. It preflights the injected microphone permission gate and claims
   AVAudioSession voice ownership; the vendored realtime SDK still performs a
   defensive permission check inside `Conversation.connect`.
3. `POST /api/voice-sessions` refreshes allowance periods before starting the
   OpenAI mint and Durable Object admission in parallel.
4. iOS performs direct WebRTC SDP negotiation with OpenAI, then waits for the
   data channel to open.
5. Local conversation lookup overlaps transport, but startup waits for it
   before attaching the transcript bridge, which must remain true to avoid
   losing early events.

## Design decisions

### 1. Preflight microphone permission before remote session creation

Store and invoke the existing `MicPermissionGate` in
`VoiceSessionPresenter`. Run it after stale/end cleanup and immediately before
audio ownership and remote session setup. A denied or undetermined result
returns `.rejected`, records the existing `.micDenied` failure, and does not
call the Worker or OpenAI. This moves the unavoidable system prompt to the
front of the flow and avoids minting an unusable remote session.

`RealtimeVoiceSession` retains its SDK-level permission behavior as a safety
net for direct/legacy callers. The presenter’s explicit preflight is the
production path and is passed as an explicit preflight state so the session
does not need to own app-level permission policy.

### 2. Make audio setup fail-fast

Make `AudioSessionCoordinator` report successful configuration/activation.
The configuration and activation effects fail instead of logging and
continuing. The presenter and the non-preflighted session path stop with the
existing `.audioSession` failure before Worker/OpenAI work begins. TTS callers
also honor the result and stop before starting playback when setup fails.

### 3. Start the local transport prewarm on ordinary reader entry

`ReaderDestination` currently prewarms only for the onboarding tour. Start the
same adapter prewarm for any authenticated reader entry. It remains
book/user-scoped, cancellable, and consumed only when the matching start uses
it. This is local object/codec preparation only; it does not claim the mic,
mint a secret, or create an OpenAI session.

### 4. Preserve the entitlement gate before provider mint

The Worker must keep `rollAllowancePeriodsForward` ahead of OpenAI ephemeral-key
minting. It rehydrates entitlement state and can reject exhausted, invalid, or
otherwise ineligible requests; minting before that gate would create unnecessary
provider credentials and change the existing security/cost contract. After the
gate, the current Durable Object admission and OpenAI mint already run in
parallel and should remain so.

### 5. Keep D1 audit mirroring off the admission response path

The Durable Object is authoritative for voice-session admission. The D1 audit
row is explicitly best-effort and the ledger already uses `ctx.waitUntil` for
similar mirror work. Schedule the `voice_session.created` and
`voice_session.call_registered` audit writes with `ctx.waitUntil` after the
authoritative local write and alarm scheduling. This does not change admission
or billing state and removes two D1 writes from startup/registration latency.

### 6. Bound book context sent to OpenAI

Normalize outline title, author, and chapter strings and cap the chapter count
before rendering the ephemeral-key request. Preserve valid existing requests,
avoid rejecting long client payloads, and keep the prompt bounded so large
books cannot inflate Worker-to-OpenAI request time and response size. The
normalization lives beside the shared realtime client-secret body builder so
both `/api/voice-sessions` and the legacy compatibility route use the same
contract.

## Preserved invariants

- Direct iOS → OpenAI WebRTC remains the media path; the Worker remains a
  credential/admission broker.
- Consent and authentication checks remain before any new remote work.
- Allowance refresh remains before Durable Object admission.
- Durable Object local state, nonce use, registration, alarms, and billing
  decisions remain synchronous and authoritative.
- Transcript stream creation remains before transport connect.
- Stale-session cleanup, retry, cancellation, and end-delivery behavior remain
  intact.
- The OpenAI ephemeral-key session configuration remains complete in the mint;
  no extra `session.update` round trip is added.

## Explicitly out of scope

- Reusing a pre-negotiated ICE/SDP session. OpenAI’s documented WebRTC flow
  creates a new offer and client-secret exchange per session; local adapter
  prewarm cannot remove that network handshake.
- Changing `gpt-realtime-2.1-mini`, voice, or audio format.
- Lowering VAD silence duration. That affects first-turn response latency, not
  initial session establishment.
- Cloudflare Smart Placement or Worker bundler changes without production
  latency evidence.
- New telemetry or benchmarking work for this change; existing traces remain
  intact.

## References

- OpenAI Realtime WebRTC guide: https://developers.openai.com/api/docs/guides/realtime-webrtc
- OpenAI Realtime client secrets: https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets
- OpenAI Realtime VAD guide: https://developers.openai.com/api/docs/guides/realtime-vad
- OpenAI `gpt-realtime-2.1-mini`: https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini
- Cloudflare Durable Object/Worker execution context patterns are represented
  by the repository’s existing `ctx.waitUntil` usage in the ledger.
