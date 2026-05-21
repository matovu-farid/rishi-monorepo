# Batch 1B — Implementation Notes & Deviations

This file captures the *judgment calls* made while executing Batch 1B
(Zustand + MMKV + XState 5 + sync consolidation on `apps/mobile`).
Each note documents a place where the literal spec didn't match the
actual code in `apps/rishi-electron` (the read-only reference), and the
shape of the deviation taken.

---

## 1. `chatStore` is not a portable text-chat store

**Spec assumption:** "chatStore.ts (+ test) — likely fully portable. Use
shared `Conversation`/`Message` types from `@rishi/shared/types/conversation`."

**Reality:** The electron `chatStore` is a thin facade around the
voice-chat service (`getVoiceChatService()`). It tracks `isChatting`,
`chatStatus`, `voiceState`, `voiceError` and forwards events into
`playerStore`, `epubStore`, `prefsStore`, plus `summarizeCurrentPage()`.
It does **not** read or write `Conversation` / `Message` records — that
work lives in `conversation-storage.ts` (mobile) and the chat thread UI.

**Decision taken:**
- Port the **public surface** (`isChatting`, `chatStatus`, set/start/stop
  actions, `dismissVoiceError`) verbatim into `apps/mobile/lib/stores/chatStore.ts`.
- Replace the in-module call to `getVoiceChatService()` with a small
  module-level injectable "port" (`setVoiceChatPort()` / a default no-op port).
- Remove the playerStore / epubStore / prefsStore / pageCapture wiring
  for now — those stores aren't ported in this batch (they belong to
  G13/G18/G24 follow-up). When the player/epub stores land on mobile,
  the wiring can be re-added in a follow-up commit.

This preserves the *identity* (selector names, action names) so future
ports can reuse the same call sites, without dragging in not-yet-ported
electron-only deps.

---

## 2. `authStore` token persistence — nothing to port

**Spec assumption:** "adapt token persistence to use `expo-secure-store`
(already a mobile dep) instead of `safeStorage`."

**Reality:** The electron `authStore` does **not** persist tokens at all.
Its persisted state is a single `rishi:welcome-seen` flag in `localStorage`.
Token persistence lives in `apps/mobile/lib/auth.ts` (already uses
`expo-secure-store`) and is unaffected by this port.

**Decision taken:**
- Port `authStore` verbatim, swap `localStorage` for the MMKV adapter.
- Leave `expo-secure-store` usage in `apps/mobile/lib/auth.ts` untouched
  — it is the canonical JWT cache and is already correct.

---

## 3. `prefsStore` does not use `localStorage`

**Spec assumption:** "swap `localStorage` storage adapter for MMKV."

**Reality:** The electron `prefsStore` reads / writes via
`window.electron.getStoreValue` / `setStoreValue` (a main-process IPC
to `electron-store`). It does **not** use `localStorage`.

**Decision taken:**
- Port the *public API* (`voiceChatLanguage`, `voiceChatVisionEnabled`,
  `ttsVisualCueEnabled`, `setVoiceChatLanguage(...)`, etc.) verbatim.
- Replace the IPC reads / writes with direct MMKV reads / writes
  (no async work needed on RN — MMKV is sync).
- `hydrate()` becomes a sync read but is still exposed as `async` so
  the public type matches electron's API (callers can `await` either).
- The `getVoiceChatService().invalidateKey()` call is replaced with a
  no-op injectable port (`setPrefsVoiceChatPort()`), same pattern as
  chatStore — voice-chat lands later on mobile.

---

## 4. `chatStore` voice-service mock seam

Both `chatStore` and `prefsStore` need a way to "tell the voice chat
service something changed" without depending on a not-yet-ported
electron service. We introduce **`apps/mobile/lib/stores/voice-chat-port.ts`**
exporting a tiny shape:

```ts
export interface VoiceChatPort {
  activate(bookId: number, ctx: ActivationContext): Promise<void>
  deactivate(): void
  invalidateKey(): void
  getState(): VoiceState
  getError(): VoiceError | null
  dismissError(): void
  onChatStatus(cb: (s: ChatStatus) => void): () => void
  onStateChange(cb: (s: VoiceState) => void): () => void
  onEndedByAgent(cb: () => void): () => void
}
```

A default `noopPort` is installed at import time, and tests / the future
voice-chat service can call `setVoiceChatPort(real)` to swap it in.

---

## 5. `connectivityMachine` ported verbatim

The electron `connectivityMachine` is **identical** to what mobile needs.
No conditional `typeof navigator` was kept for mobile (RN has no
`navigator.onLine`); the machine simply defaults to `online` and lets the
adapter feed it `ONLINE`/`OFFLINE` events from NetInfo.

The `MobileConnectivityPort` adapter (in
`apps/mobile/lib/connectivity/MobileConnectivityPort.ts`) implements
the shared `ConnectivityPort` interface from
`@rishi/shared/connectivity/types`. NetInfo's listener subscription
returns an unsubscribe fn, which we wire to xstate `send(...)`.

---

## 6. `sync engine` consolidation — partial

**Approach:**
- Introduce **`apps/mobile/lib/sync/drizzle-adapter.ts`** — a
  `SyncDbAdapter` (from `@rishi/shared/sync-adapter`) implemented
  against mobile's drizzle DB. All the SQL that lived inline in
  `engine.ts` moves here.
- **`apps/mobile/lib/sync/engine.ts`** becomes a *thin* wrapper that:
  1. Calls `markSyncInProgress(true/false)` (mobile-specific).
  2. Calls `setSyncStatus(...)` (mobile-specific).
  3. Delegates the actual push/pull cycle to
     `createSyncEngine({ adapter: mobileDrizzleAdapter, apiFetch: apiClient })`
     from `@rishi/shared/sync-engine`.
- The existing `sync()` export shape is preserved, so callers
  (`triggers.ts`, app code) keep working.

**Tests:** the existing `__tests__/sync.test.ts` mocks the inline SQL
shape. With logic moved to the shared engine + adapter, those tests
no longer apply 1:1. The two existing failures in `sync.test.ts` were
**pre-existing on `main`** (see baseline below) — this batch does not
attempt to "fix" them. New adapter-level tests in `sync-adapter.test.ts`
cover the conflict / clean-mark behaviour at the adapter seam, which is
the appropriate test boundary now.

**Baseline failures before this batch (recorded for honesty):**
- `__tests__/sync.test.ts` (2 failing tests; pre-existing)
- `__tests__/vector.test.ts` (1 failing test; pre-existing)
- `__tests__/guardrails.test.ts` (1 failing test; pre-existing)

---

## 7. `react-native-mmkv` in `jest` / Node

MMKV is a JSI module — it does **not** load under plain `ts-jest` (no
RN runtime). The adapter exports a small `createStorage()` factory that:
- In RN runtime → uses a real `new MMKV()` instance
- In test/Node → uses an in-memory `Map` fallback when MMKV is
  unavailable (detected at construction time)

This lets `__tests__/mmkv.test.ts` and every store test exercise the
adapter contract without spinning up a RN host. Production code paths
always hit the real MMKV.

---

## 8. Items not ported in this batch (kept for follow-ups)

- `playerStore`, `paragraph`, `selectionStore`, `indexingStore`,
  `pdfStore`, `epubStore`, `navStore` (depend on electron services).
- `playerMachine`, `pdfReaderMachine`, `navMachine` (same).
- The voice-chat service itself — `chatStore` / `prefsStore` use the
  port shape documented in #4 above and will be wired up when the
  service lands.
- Auto-sync UI wiring on mobile (status badge) — unchanged.

---

## 9. Code we wanted to share but couldn't cleanly extract

- The mobile-specific `markSyncInProgress` / `wasSyncInterrupted`
  helpers in `apps/mobile/lib/db.ts` are very close to the electron
  equivalents in main-process IPC, but use different storage
  primitives (sqlite WAL marker vs. electron-store). A shared
  "interrupted-sync marker" is a candidate for a future Batch 1C/D —
  left here untouched.
- The `setSyncStatus` listener mechanism in `apps/mobile/lib/sync/status.ts`
  is functionally the same as electron's renderer-side `SyncStatusService`
  but with a different (`status`, `lastSyncAt`) tuple shape vs. the
  shared `SyncStatusSnapshot` `{ status, lastSyncAt }`. Renaming the
  mobile shape is breaking and was deferred.
