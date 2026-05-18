# TanStack AI Realtime Migration — Design Spec

**Date:** 2026-05-19
**App:** `apps/rishi-electron`
**Status:** Draft for review

## Motivation

The current voice-chat realtime flow uses `@openai/agents/realtime` (`RealtimeAgent`, `RealtimeSession`) and `@openai/agents-realtime` (`OpenAIRealtimeWebRTC`). This is the wrong abstraction layer for our use case: it's low-level enough to require an xstate machine and an Effect-TS activation pipeline to wrap it, yet provider-locked enough to make future provider changes invasive.

Migrating to TanStack AI (`@tanstack/ai-client`, `@tanstack/ai-openai`, `@tanstack/ai`) replaces those two packages with a higher-level `RealtimeClient` that owns WebRTC, mic acquisition, audio-element wiring, status/mode events, and tool dispatch. We delete the xstate machine and the Effect activation pipeline as redundant.

The migration stays on OpenAI Realtime as the only backend, but the adapter boundary leaves a clean seam for future providers (ElevenLabs) without restructure.

## Decisions

| Axis | Choice | Rationale |
|---|---|---|
| Provider scope | OpenAI-only now, seam for later (`adapter` is the only OpenAI-specific call site) | Avoids designing for hypothetical multi-provider while preserving the option |
| Wrapper scope | Keep `voiceChatService` facade, drop xstate + Effect activation pipeline | Cross-cutting policies (inactivity, connectivity, key cache, sounds) are still ours; the SDK-glue layer is redundant under TanStack AI |
| Warm path | Preserve via `client.updateSession({ instructions })` | TanStack AI explicitly documents `updateSession()` for OpenAI Realtime; avoids 1-3s reconnect on page-turns mid-chat |
| Token shape | Client-side envelope around existing worker string | Worker is shared with Tauri/Dioxus apps; backend change forces lockstep migration |
| Test strategy | T3 hybrid — mock `clientFactory` for policy tests, one `fake-adapter` wiring-truth test | Fast unit coverage for cross-cutting policies + one truth test catches mock/real API drift |

## Architecture

```
React components (chatStore, FileComponent)
        │
        ▼
VoiceChatService (interface — unchanged)
        │
        ▼  ┌──────────────────────────────────────────┐
        │  │ services/voice-chat/service.ts           │
        │  │  - inactivity timer, key cache,          │
        │  │    connectivity gate, sound effects,     │
        │  │    cold/warm path orchestration          │
        │  │  - status-mapper                         │
        │  └──────────────────────────────────────────┘
        │
        ▼
RealtimeClient (@tanstack/ai-client)
        │
        ▼
openaiRealtime() adapter (@tanstack/ai-openai)
        │
        ▼
OpenAI Realtime API over WebRTC (with mic + audio el managed by the client)
```

The `VoiceChatService` public interface (`start/stop/activate/preconnect/deactivate/dispose/prewarmKey/invalidateKey/getState/getError/dismissError/onStateChange/onChatStatus/onEndedByAgent`) is preserved exactly. Consumers (`chatStore`, `epubStore` side-effects, `FileComponent`) require no changes.

## File-level changes

### Added

- `services/voice-chat/buildRealtimeConfig.ts` — pure function returning `{ instructions, tools, voice, model? }`. Consumed by `RealtimeClient` constructor and `client.updateSession()`. Replaces `modules/buildRealtimeAgent.ts`.
- `services/voice-chat/buildRealtimeConfig.test.ts` — tests instruction templating, language/outline/active-paragraph sections, tool wiring including Effect-wrapped Sentry/error-dump for bookContext and endConversation.
- `services/voice-chat/realtime-token.ts` — exports `fetchRealtimeToken(language): Promise<RealtimeToken>` that wraps the existing worker string in TanStack AI's envelope shape.
- `services/voice-chat/realtime-token.test.ts` — verifies envelope shape and expiry math.
- `services/voice-chat/status-mapper.ts` — pure function mapping `RealtimeStatus + RealtimeMode + ourFlags → VoiceChatPublicState + ChatStatus`.
- `services/voice-chat/status-mapper.test.ts` — table-driven mapping tests covering all combinations.
- `services/voice-chat/fake-adapter.ts` (test-only) — minimal `RealtimeAdapter` implementation for the T2 wiring-truth integration test.

### Changed

- `services/voice-chat/service.ts` — internals rewritten. Public `VoiceChatService` interface preserved. Loses `createActor`, `voiceChatMachine`, Effect imports, activation-program. Gains `RealtimeClient` instantiation and status-mapper plumbing. Cross-cutting policies (inactivity timer, key cache, connectivity gate, sound effects) become plain-TS composition inside the facade body.
- `services/voice-chat/types.ts` — `VoiceChatServiceDeps` ports change:
  - **Drop:** `webrtcFactory`, `agentFactory`, `sessionFactory`, `media` (mic + audio element managed by `RealtimeClient`)
  - **Add:** `clientFactory(opts): RealtimeClient`, `adapter: RealtimeAdapter`
  - **Keep:** `rag`, `connectivity`, `ipc`, `effects`, `clock`, `config`, `getLanguage`
  - Public state unions (`VoiceChatPublicState`, `ChatStatus`, `VoiceErrorReason`) unchanged.
- `services/voice-chat/service.test.ts` — rewritten against new deps shape. Most behavior assertions survive: inactivity, connectivity, error classification, warm/cold path, tool empty-result observability.
- `services/voice-chat/key-cache.ts` — fetcher signature changes from `() => Promise<string>` to `() => Promise<RealtimeToken>`. Expiry math switches from hard-coded `keyTtlMs` to `expiresAt - clock.now()` (more correct).
- `services/voice-chat/key-cache.test.ts` — updated for new fetcher signature and expiry-based TTL.
- `services/voice-chat/errors.ts` — keep `MicDeniedError`, `AuthFailedError`, `ConnectTimeoutError`, `ConnectFailedError`, `SessionError`, `toPublicError`. Drop Effect-specific tagged-error wiring (we no longer build the pipeline with `Effect.tryPromise`).
- `services/voice-chat/errors.test.ts` — drops Effect-tagged tests; keeps `toPublicError` coverage.
- `services/index.ts` — wires `openaiRealtime()` adapter and `clientFactory` (constructs `RealtimeClient` from deps). Deletes `RealtimeSession`/`OpenAIRealtimeWebRTC` imports.
- `lib/api.ts` — `getRealtimeClientSecret` signature unchanged (still returns `string`); a new `getRealtimeToken` wrapper applies the envelope before handing to the facade. Optionally `getRealtimeClientSecret` is kept for backward compat during the migration commit and removed after.
- `package.json` — add `@tanstack/ai-client`, `@tanstack/ai-openai`, `@tanstack/ai`; remove `@openai/agents` and `@openai/agents-realtime` after migration verification passes.

### Deleted

- `services/voice-chat/machine.ts`
- `services/voice-chat/machine.test.ts`
- `services/voice-chat/activation-program.ts`
- `modules/buildRealtimeAgent.ts`
- `modules/buildRealtimeAgent.test.ts`

## Data and control flow

### Cold path (no live session for the requested `bookId`)

1. `activate(bookId, ctx)` checks `connectivity.isOnline()` → throws `OfflineError` if offline.
2. `keyCache.get()` returns a cached or freshly minted `RealtimeToken`.
3. `buildRealtimeConfig({ bookId, ctx, rag, language, onEndConversation })` returns `{ instructions, tools, voice }`.
4. `clientFactory({ adapter, getToken: () => keyCache.get(), instructions, tools, voice, onStatusChange, onModeChange, onMessage })` constructs a `RealtimeClient`.
5. `await client.connect()` is raced against `connectTimeoutMs`. Mic acquisition and audio-element wiring happen inside `connect()`.
6. On success: stash client, `bookId`, ctx fingerprint, emit `active` + `idle`, schedule inactivity timer.
7. On failure: classify (`mic_denied` from `NotAllowedError`/`NotFoundError`, `auth_failed` from `getToken` rejection, `timeout` from the race, `connect_failed` otherwise), emit `error`, `client.destroy()`.

### Warm path (live session, same `bookId`)

1. Compute ctx fingerprint (same exclusion of `activeParagraphText` as today — paragraph advances would otherwise re-upload instructions on every TTS paragraph).
2. If fingerprint changed: `await client.updateSession({ instructions: newInstructions })`. Tools rarely change; we pass the full config defensively.
3. If fingerprint unchanged: no-op beyond unmuting.

### Different `bookId`

Full dispose (close client, run cleanup) then cold path.

### Lifecycle event mapping

| Source | Emit |
|---|---|
| `onStatusChange('connecting' \| 'reconnecting')` | `VoiceChatPublicState.connecting` |
| `onStatusChange('connected')` | `VoiceChatPublicState.active`, `ChatStatus.idle` |
| `onStatusChange('idle')` after connect | dispose path |
| `onStatusChange('error')` | `VoiceChatPublicState.error` with classified reason |
| `onModeChange('thinking')` | `ChatStatus.thinking`, start thinking sound on first tool entry |
| `onModeChange('speaking')` | `ChatStatus.speaking`, play ready chime on first speaking transition |
| `onModeChange('idle' \| 'listening')` | `ChatStatus.idle`, stop thinking sound |

All emits reset the inactivity timer.

### Tool calls

`bookContext` and `endConversation` migrate from `@openai/agents/realtime`'s `tool()` to `@tanstack/ai`'s `toolDefinition().client()`. Zod schemas are reused as-is. The `runToolCall` Effect wrapper (console + `dumpError` + Sentry) wraps each `.client(execute)` function unchanged. `endConversation` calls `onEndConversation(reason)` via closure to the `endedByAgentEmitter`.

## Token shape

The shared worker (`${WORKER_URL}/api/realtime/client_secrets`) returns a bare client_secret string. TanStack AI's `RealtimeToken` expects `{ token, provider, expiresAt, config }`.

To avoid forcing the Tauri and Dioxus apps into a lockstep worker migration, we wrap the worker response client-side in `services/voice-chat/realtime-token.ts`:

```typescript
export async function fetchRealtimeToken(language: string): Promise<RealtimeToken> {
  const secret = await api.getRealtimeClientSecret(language)
  return {
    token: secret,
    provider: 'openai',
    expiresAt: Date.now() + 9 * 60 * 1000, // worker mints 10-min TTL; we cushion by 1 minute
    config: {} // config is embedded server-side in the ephemeral key
  }
}
```

**Verification item for the implementation plan:** confirm `RealtimeClient` accepts an envelope with empty `config` and doesn't require the renderer to repeat session config it already gets through `RealtimeClient` constructor props. If non-empty `config` is required, mirror `buildRealtimeConfig()` output into the envelope.

## Provider seam

`services/index.ts` constructs `openaiRealtime()` and injects it via `voiceChatServiceDeps.adapter`. The facade itself never imports from `@tanstack/ai-openai`. Switching to `elevenlabsRealtime()` is a one-line composition-root change.

OpenAI Realtime is the only provider that supports `updateSession()` for live instruction reconfigure. The facade's warm path is therefore OpenAI-specific behavior. If a future provider adapter is added that doesn't support live updates, the facade detects this (a `capabilities.supportsUpdateSession` field on the adapter, or feature-detection via `'updateSession' in client`) and gracefully degrades to "reconnect on context change" for that provider.

## Error handling

| Error | Trigger |
|---|---|
| `MicDeniedError` | `connect()` rejection with `name === 'NotAllowedError'` or `'NotFoundError'` |
| `AuthFailedError` | `getToken` rejection (worker non-OK or transport failure) |
| `ConnectTimeoutError` | `Promise.race(connect(), timeout)` times out |
| `ConnectFailedError` | Any other `connect()` rejection |
| `SessionError` | `onStatusChange('error')` after a successful connect |
| `OfflineError` | `connectivity.isOnline()` false at activate |

All errors flow through `toPublicError` and into the existing `VoiceError` surface unchanged. `chatStore` consumers see the same `VoiceErrorReason` union as today.

## Test plan (T3 hybrid)

### Unit tests with mock `clientFactory`

`service.test.ts` rewritten to inject a fake `RealtimeClient` that mirrors the public surface (`connect`, `disconnect`, `updateSession`, `sendText`, `destroy`, `onStatusChange`, `onModeChange`, `onMessage`, `onStateChange`). Tests cover:

- State transitions: `idle → connecting → active → idle` on dispose
- Cold path success and each failure class (`mic_denied`, `auth_failed`, `timeout`, `connect_failed`)
- Warm path: same `bookId` + fingerprint change → `updateSession` called, no `connect`
- Warm path: same `bookId` + fingerprint unchanged → no-op
- Different `bookId` → dispose + cold path
- Inactivity timer fires `endedByAgent('inactivity_timeout')` and disposes
- Connectivity: offline → dispose; reconnect transition on online
- Key cache respects `expiresAt` from token envelope
- Tool empty-result emits `dumpError` but not Sentry; tool throw emits both and returns fallback
- Language change invalidates cached key

### Wiring-truth test with `fake-adapter.ts`

One integration test instantiates a real `RealtimeClient` against a fake `RealtimeAdapter` (test-only implementation of the adapter contract). Verifies:

- `client.connect()` calls `getToken` and then `adapter.connect()` with token in payload
- `client.updateSession({ instructions })` reaches the adapter's update path
- A tool-call event from the adapter routes to our `toolDefinition().client(execute)` and the result routes back via `addToolResult`

This test exists to catch drift between our mock `clientFactory` and the real `RealtimeClient` API. It runs in the same vitest suite.

### Preserved tests

`emitter.test.ts`, `errors.test.ts` (Effect-tagged tests dropped), `types.test.ts` — survive with minimal or no edits. `key-cache.test.ts` updated for the fetcher signature change.

## Migration order (TDD)

Per the repo's TDD policy (red-green-refactor, plan tests before implementation), the implementation plan will sequence:

1. Red: write `status-mapper.test.ts` against the new mapping. Implement `status-mapper.ts`.
2. Red: write `realtime-token.test.ts`. Implement `realtime-token.ts`.
3. Red: write `buildRealtimeConfig.test.ts` (tool wrapping + instruction templating). Implement `buildRealtimeConfig.ts`.
4. Red: write rewritten `service.test.ts` against new ports. Implement new `service.ts`.
5. Red: write the `fake-adapter.ts` + wiring-truth test. Implement against real `RealtimeClient`.
6. Update `services/index.ts` composition root.
7. Delete `machine.ts`, `activation-program.ts`, `buildRealtimeAgent.ts` (and their tests).
8. Remove `@openai/agents` / `@openai/agents-realtime` from `package.json`.
9. E2E smoke: launch app, activate voice on a book, confirm tool call, page turn (warm path), inactivity timeout.

## Non-goals

- ElevenLabs or any second provider — explicitly deferred.
- Backend worker changes — explicitly deferred to keep Tauri/Dioxus apps independent.
- Component-level migration to `useRealtimeChat` (would couple voice chat to React; the facade pattern serves non-React callers and tests).
- Replacing other AI surfaces (RAG, embeddings, text chat) — out of scope.

## Risks and verification items

| Risk | Mitigation |
|---|---|
| `RealtimeClient` rejects empty `config` in token envelope | Verification step in implementation plan; mirror `buildRealtimeConfig()` into envelope if needed |
| `onModeChange('thinking')` fires only on LLM reasoning, not tool execution | Acceptable behavior change for sound effects; flag in plan; could fall back to listening to messages for `tool_call`/`tool_result` events |
| `client.updateSession()` requires fields beyond `instructions` | Pass full `buildRealtimeConfig()` output defensively |
| Mic permission UX differs from `@openai/agents/realtime` | E2E smoke test; verify `NotAllowedError` still propagates cleanly |
| Worker token TTL changes | Token envelope uses fixed 9-minute cushion; if worker policy changes, only `realtime-token.ts` constants need update |

## Out of scope changes considered and rejected

- **Wholesale `useRealtimeChat` migration (collapse facade entirely).** Rejected: couples voice chat to React, breaks non-React callers and the existing service-layer pattern.
- **Backend-side `realtimeToken()` adoption.** Rejected: forces lockstep migration in Tauri and Dioxus apps. Revisit if/when those apps migrate.
- **Provider-agnostic warm path.** Rejected: `updateSession()` is an OpenAI-only capability per TanStack AI docs. Designing around the lowest common denominator (reconnect) would regress today's UX for no near-term benefit.
