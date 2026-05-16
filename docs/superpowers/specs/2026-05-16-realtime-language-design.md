# Realtime API language pinning — design

## Problem

Voice chat uses OpenAI's Realtime API (`gpt-realtime`) and currently passes no language constraint at any layer. When a user with a heavy English accent speaks, OpenAI's internal speech-understanding sometimes misclassifies the input as another language and the model responds in that other language. The current code has:

- Worker session config with no `audio.input.transcription.language` (`workers/worker/src/index.ts:165-198`)
- Agent instructions with no language constraint (`apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:128-160`)
- No user preferences store anywhere in the renderer

## Goal

Pin the realtime conversation to a user-chosen language (default English) so accent-driven misclassification stops causing wrong-language responses.

## Non-goals

- Per-book language override
- OS-locale auto-detection on first run
- Auto-detection of language from page text (deliberately rejected — page language ≠ user's preferred chat language)
- Mid-session language switching (setting changes apply on next `activate()`)
- A general settings UI for prefs beyond this one dropdown

## Approach summary

Introduce a single user preference `voiceChatLanguage` (ISO-639-1 string, default `"en"`), persisted to a JSON file in the main process via a generic `prefs:get` / `prefs:set` IPC pair. The language is read at *two* sites at activation time:

1. The worker key request — passes language into `audio.input.transcription.language` so Whisper's STT path is locked, fixing the root cause.
2. The agent instructions — adds a "Respond in {LANGUAGE_NAME}" line so the model's response language is constrained even if internal speech understanding wavers.

Both reads happen synchronously from a Zustand store that hydrates from IPC at app boot.

## Architecture

```
┌─────────────────────────────────────┐
│ Settings UI (account.tsx)           │   ← user picks language
│   <select> → prefsStore.setLanguage │
└──────────────┬──────────────────────┘
               │
               ▼
       ┌───────────────┐         IPC: prefs:get / prefs:set
       │  prefsStore   │  ◄──────────────────────────────►  main: prefs.json
       │  (zustand)    │                                    in app userData/
       └───┬───────────┘
           │ language
           ├──────────────────────────────────────┐
           ▼                                      ▼
  buildRealtimeAgent()                   getRealtimeClientSecret(language)
  - inserts "Respond in {LANG}"          - sends ?language=en to worker
    line into instructions

                                         worker /api/realtime/client_secrets
                                         - sets session.audio.input.transcription.language
```

## Components

### 1. `prefsStore.ts` (new) — `apps/rishi-electron/src/renderer/src/stores/prefsStore.ts`

Zustand store. Single key `voiceChatLanguage` (default `"en"`). Hydrates lazily on first read via `window.electron.getPref('voiceChatLanguage')`. `setLanguage(lang)` writes through to IPC, calls `getVoiceChatService().invalidateKey()` (matching the existing pattern in `chatStore.ts:3` of stores reaching into the service singleton), then updates state.

Why a store rather than a hook: the worker-key fetch (`getRealtimeClientSecret`) and the agent factory both need this synchronously at activation time. A store gives them a sync read (`usePrefsStore.getState().voiceChatLanguage`) without an IPC round-trip on every voice-chat start.

### 2. Main-process prefs handler (new) — `apps/rishi-electron/src/main/ipc/prefs.ts`

Two channels added to `ipc-contract.ts`:

- `prefs:get` — `(key: string) => unknown | null`
- `prefs:set` — `(key: string, value: unknown) => void`

Backed by a single JSON file at `app.getPath('userData')/prefs.json`. Read on first call into memory; writes go through a debounced flush (50ms) to avoid hammering disk on rapid changes. The channel is intentionally generic so future prefs (theme, default voice, etc.) don't need new IPC channels.

### 3. Worker change — `workers/worker/src/index.ts:165`

Accept `?language=xx` query param. Validate against the allow-list:

```ts
const ALLOWED_LANGUAGES = ['en','es','fr','de','it','pt','ja','ko','zh','ar','hi','ru'] as const
```

Fall back to `"en"` if missing or invalid. Inject into the OpenAI session body:

```ts
session: {
  type: "realtime",
  model: "gpt-realtime",
  instructions: "You are a friendly assistant.",
  audio: {
    input: { transcription: { language } }
  }
}
```

The allow-list (vs free-form) prevents a malicious or buggy client from sending garbage that breaks the OpenAI request.

### 4. `getRealtimeClientSecret(language)` — `apps/rishi-electron/src/renderer/src/lib/api.ts:331`

Add a `language` parameter. Append as query string to the worker URL. Caller (the voice-chat service's `keyCache` in `services/voice-chat/service.ts:60-64`) reads the language from `prefsStore` at fetch time.

### 5. `buildRealtimeAgent` — `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:128`

Add a `language` field to `BuildAgentOptions`. Insert a single section near the top of the instructions template, between Role and Outline:

```
## Language
Always respond in {LANGUAGE_NAME} regardless of the user's accent or pronunciation. Treat all input as {LANGUAGE_NAME} unless the user explicitly switches mid-conversation.
```

Use a `LANG_LABELS` map keyed off the same allow-list as the worker. Pass language *names* (e.g., `"English"`, `"Spanish"`) into the prompt rather than raw ISO codes — the model handles names better. Unknown codes fall back to `"English"`.

### 6. Settings UI — `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx`

A new section "Voice chat language" with a `<select>` of the 12 allow-list languages, bound to `usePrefsStore`. No save button — change commits on `onChange`.

### 7. Cache-key invalidation — `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts`

The realtime ephemeral-key cache (TTL 9min, see `services/index.ts:267`) caches a key minted with whatever language was active at fetch time. If the user changes language while a key is cached, the next chat would use a key minted for the old language.

Resolution: `prefsStore.setLanguage` calls `voiceChatService.invalidateKey()` after the IPC write succeeds. Add an `invalidate(): void` method to the key-cache (`key-cache.ts`) and surface it as `invalidateKey(): void` on the `VoiceChatService` interface in `services/voice-chat/types.ts`.

## Data flow at activation

1. User clicks voice-chat button → `chatStore` calls `voiceChat.activate(bookId, ctx)`.
2. Service reads `usePrefsStore.getState().voiceChatLanguage` (sync, hydrated at boot).
3. Service passes language to `agentFactory({ ..., language })` — agent instructions get the language line.
4. Service passes language to `keyCache.get()` → `getRealtimeClientSecret(language)` → worker `?language=xx` → OpenAI session config sets `transcription.language`.
5. Realtime session connects; both transcription and response are pinned.

## Error handling

- **Pref file missing / corrupt** — main returns `null` for `prefs:get`; store falls back to `"en"`. No surfaced error — fresh-install behavior matches corrupt state.
- **Worker receives invalid `language`** — silently coerce to `"en"` (log on worker). Only triggers for tampered or out-of-sync clients.
- **`session.audio.input.transcription.language` rejected by OpenAI** (e.g., API shape changes) — worker returns 500 to the renderer, which surfaces as the existing `connect_failed` flow. No new error type.
- **Language change mid-active-chat** — out of scope. Setting changes apply on the next `activate()`. The current session keeps its language. One-line comment in `prefsStore.setLanguage` documents this.

## Edge cases

- **Hydration race** — if voice chat is started before `prefsStore.hydrate()` resolves, the store returns the default `"en"`. Hydrate is kicked off at app boot in `services/index.ts` initialization so the window is sub-50ms.
- **Cache invalidation order** — `setLanguage` awaits the IPC write, then synchronously calls `voiceChatService.invalidateKey()` (no async work inside it) before returning, so the next `activate()` definitely sees the new value.
- **First-run users with non-English locale** — they get English until they change the setting. Accepted tradeoff (user base is mostly English speakers).

## Testing (TDD)

Tests are written first, per repo convention (red-green-refactor). Each component gets an isolated unit test:

| File | What to test |
|---|---|
| `stores/prefsStore.test.ts` (new) | Default is `"en"`; hydrates from IPC mock; `setLanguage` writes via IPC and invalidates voice-chat key |
| `main/ipc/prefs.test.ts` (new) | `get` returns null for missing key; `set` then `get` round-trips; corrupt JSON → `get` returns null without throwing |
| `modules/buildRealtimeAgent.test.ts` (extend) | Instructions include the language line for `'en'`, `'es'`; falls back to English for unknown code |
| `workers/worker/src/realtime.test.ts` (new — workers package has no existing tests) | `?language=es` injects `es` into OpenAI request body; missing/invalid → `en`; payload includes `audio.input.transcription.language`. May require extracting the route handler from `index.ts` into a testable module. |
| `services/voice-chat/service.test.ts` (extend) | Activate flow passes `language` from prefs into `agentFactory` and `getRealtimeClientSecret` |
| `services/voice-chat/key-cache.test.ts` (extend) | `invalidate()` clears cached key; next `get()` re-fetches |

No new E2E tests — the existing voice-chat E2E covers the activation path; this change doesn't alter the user-visible flow shape.

## Files touched

**New:**
- `apps/rishi-electron/src/renderer/src/stores/prefsStore.ts`
- `apps/rishi-electron/src/renderer/src/stores/prefsStore.test.ts`
- `apps/rishi-electron/src/main/ipc/prefs.ts`
- `apps/rishi-electron/src/main/ipc/prefs.test.ts`

**Modified:**
- `apps/rishi-electron/src/preload/ipc-contract.ts` — add `prefs:get`, `prefs:set`
- `apps/rishi-electron/src/main/index.ts` — register prefs IPC handler
- `apps/rishi-electron/src/renderer/src/lib/api.ts` — `getRealtimeClientSecret(language)`
- `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts` — language param + instructions section
- `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts` — extend coverage
- `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts` — add `language` to `BuildAgentOptions`, `invalidateKey()` on service
- `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts` — `invalidate()` method
- `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts` — extend
- `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts` — read pref, pass to factory and key fetch
- `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts` — extend
- `apps/rishi-electron/src/renderer/src/services/index.ts` — wire `voiceChatLanguage` into factory init, hydrate prefs at boot
- `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx` — add language select section
- `workers/worker/src/index.ts` — accept and validate `?language=`, inject into session body (route handler may be extracted to `workers/worker/src/routes/realtime.ts` to be unit-testable)
- `workers/worker/src/realtime.test.ts` — new test file (workers package currently has no tests; vitest config may need to be added)
