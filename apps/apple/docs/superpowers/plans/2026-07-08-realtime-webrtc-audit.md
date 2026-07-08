# Realtime WebRTC Audit

> **Source of truth first:** the official OpenAI Realtime docs come before our local package or any upstream fork.

**Goal:** Make the voice feature work reliably by moving to the documented OpenAI WebRTC path. Keep the audio experience. Reduce the amount of custom realtime plumbing that can drift.

**Official docs to check first:**
- [Realtime API with WebRTC](https://developers.openai.com/api/docs/guides/realtime-webrtc)
- [Realtime with tools](https://developers.openai.com/api/docs/guides/realtime-mcp)

**Why this path:**
- OpenAI says WebRTC is the recommended client path for realtime voice apps.
- The browser/mobile client handles the audio connection.
- The server stays in the middle for session setup and tool wiring.
- That should reduce the number of custom moving parts compared with our current wrapper-based path.

---

## 1. Read the docs first

What to confirm:
- how the client creates the SDP offer
- how the worker turns that offer into an OpenAI session
- how the answer comes back to the client
- where tools belong in the session
- how tool calls and tool outputs are supposed to flow

Exit condition:
- we have a short checklist of the documented WebRTC session flow and tool flow

---

## 2. Map our code to the documented flow

Check these pieces:

- Worker session setup: `workers/worker/src/index.ts`
- Worker tests: `workers/worker/src/realtime-client-secrets.test.ts`, `workers/worker/src/shared-spec-smoke.test.ts`
- Apple voice entry and session code: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift`, `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift`, `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeEventPump.swift`
- Current tool responder: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeToolCallDispatcher.swift`, `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/BookContextResponder.swift`
- Current realtime package: `apps/apple/Packages/swift-realtime-openai/Sources/Core/Models/Response.swift`, `apps/apple/Packages/swift-realtime-openai/Sources/Core/Models/ServerEvent.swift`, `apps/apple/Packages/swift-realtime-openai/Sources/UI/Conversation.swift`

What to look for:
- are we still relying on a custom client wrapper where the docs expect a WebRTC session?
- is the worker preparing the session in the way the docs describe?
- can the app talk to the session through the WebRTC data channel instead of waiting on a custom event pump?
- do we still need the vendored SDK at all, or only a smaller slice of it?

Exit condition:
- we know exactly which pieces are still useful and which pieces are just extra wrapper code

---

## 3. Move to the WebRTC path

Keep:
- the worker as the trusted server-side setup point
- the bookContext tool
- the book-context responder
- the audio UX in the app

Change:
- use the documented WebRTC connection flow instead of the current custom realtime wrapper path
- send the SDP offer from the client to the worker
- have the worker create the realtime session with the documented tool setup
- return the SDP answer to the client
- let the client connect and receive the realtime events through the WebRTC data channel

Exit condition:
- the app connects through WebRTC, not through the old wrapper path
- tool calls still reach the book responder

---

## What to verify after the switch

- audio still works
- the worker still sends the `bookContext` tool
- the app still gets the tool call
- the book responder still returns context
- the old hanging behavior is gone

## What to avoid

- do not reimplement the whole voice stack
- do not keep patching the upstream package if the WebRTC path makes most of it unnecessary
- do not change the book search logic if it already works
