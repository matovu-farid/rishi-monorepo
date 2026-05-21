# Batch 1C — Implementation Notes & Deviations (2026-05-21)

Mobile auth swap from Clerk → Better-Auth deep-link, matching electron's
session model.

---

## Summary

| Layer       | Action                                                                     |
| ----------- | -------------------------------------------------------------------------- |
| Worker      | Already shipped in Batch 1A (`/mobile/start`, `/start/verify`). Untouched. |
| `@rishi/shared` | New `auth/pkce.ts` (Web-Crypto portable) + `auth/startAuthSession.ts`.  |
| Mobile      | `lib/auth.ts` rewritten; `lib/api.ts` simplified; `authStore` extended.    |
| Mobile UI   | `app/(auth)/sign-in.tsx` and (auth/tabs/root) `_layout.tsx` swapped.       |
| Mobile pkg  | `@clerk/expo` removed; `package-lock.json` regenerated via `npm install`.  |
| Mobile cfg  | `app.json` plugins: `-@clerk/expo`, `+expo-web-browser`.                   |

---

## 1. PKCE: shared module is async, but the source was sync

**Spec assumption:** "Copy `apps/rishi-electron/src/main/auth/pkce.ts` into
`packages/shared/src/auth/pkce.ts`. If electron's version uses Node
`crypto`, write a platform-portable version: use Web Crypto APIs."

**Reality / decision:**
- Electron's `pkce.ts` is **synchronous** because Node's `createHash` is
  sync.
- Web Crypto's `crypto.subtle.digest` is **async** (returns a Promise).
- The shared portable version therefore had to make both `generatePkcePair`
  and `verifyPkce` `Promise`-returning. Callers updated accordingly.
- Electron's `pkce.test.ts` already used `await verifyPkce(...)` — JS
  happily awaits a sync boolean, so the shape "test treats it as async"
  was already in place upstream. Migrating callers (if/when electron
  switches to the shared module) is a no-op at the call site.

**Electron's own `pkce.ts` is NOT replaced in this batch.** Touching
electron is explicitly out of scope ("Electron remains read-only").

---

## 2. PKCE: `react-native-get-random-values` polyfill

**Spec mention:** "React Native has `crypto.getRandomValues` via
`expo-crypto` or `react-native-get-random-values` polyfill — add the
polyfill if not already present in mobile."

**Reality / decision:**
- `expo-crypto` (~15.0.8) is already a mobile dependency. Per the
  expo-crypto docs, importing it as a side-effect installs
  `crypto.getRandomValues` globally.
- `apps/mobile/lib/auth.ts` starts with `import 'expo-crypto'` to trigger
  that polyfill before `@rishi/shared/auth/pkce` is loaded.
- No new RN dep was added; `react-native-get-random-values` is
  superfluous when `expo-crypto` is present.
- In jest (node env), the test file polyfills with
  `require('node:crypto').webcrypto` because expo-crypto is mocked.

---

## 3. Token transport: deep-link URL vs. verifier exchange

**Worker contract (from Batch 1A):**
- `POST /mobile/start` → `{ state, authUrl }`
- `GET /mobile/start/complete` (browser redirect target) → 302 →
  `rishimobile://auth/callback?state=<state>` (NO token in URL)
- `POST /mobile/start/verify { state, code_verifier }` → `{ session_token, user_id }`

The token is **never** in the deep-link URL. The mobile client must do
two HTTP calls.

**This batch implements that contract exactly.** `lib/auth.signIn()`
opens the browser, observes the `state` in the callback URL, and POSTs
to `/mobile/start/verify` with the (memory-only) verifier. The token
is then written to `expo-secure-store`.

---

## 4. `lib/api.ts` simplification: no more Clerk exchange

**Spec assumption:** "`apps/mobile/lib/auth.ts` currently calls
`/api/auth/exchange` which doesn't exist (dead code from Clerk era)."

**Reality / decision:**
- `lib/api.ts` had a Clerk-exchange step where it called
  `getClerkToken()` and POSTed it to `/api/auth/exchange`. That path
  is fully dead post-1C — the Better-Auth session token IS the worker
  bearer. No exchange step.
- New `apiClient`: read token from `expo-secure-store`, attach as
  `Authorization: Bearer <token>`. On 401, call `signOut()` (which
  wipes the cache) and throw so the caller can route to `/sign-in`.
  No silent retry — the user has to re-run the deep-link flow.
- `initApiClient(_getToken?)` kept as a **no-op** for source compat
  (older callers passed a Clerk token getter; nothing depends on the
  Clerk seam anymore). Marked `@deprecated`. Can be removed in a
  follow-up grep.

---

## 5. Mobile authStore — `setSession` vs. token persistence

**Decision:**
- Token is owned by `expo-secure-store` (under `rishi.bearer`).
- `authStore.sessionToken` is an **in-memory mirror** that exists so
  React components can read it synchronously without an async call to
  secure-store each render.
- `setSession(token, userId, email?)` writes the in-memory token + user,
  flips `isAuthenticated`, and persists ONLY the `userId` to MMKV.
  The token deliberately never lands in MMKV (security: MMKV is plain
  file-backed; secure-store is OS Keychain on iOS / EncryptedSharedPreferences
  on Android).
- `clearSession()` wipes both the in-memory token AND the persisted user
  id. The actual secure-store deletion is done by `lib/auth.signOut()`.
- `hydrateAuth()` restores the last-known `user.id` from MMKV so the UI
  knows who we were while `getSessionToken()` resolves.

---

## 6. `expo-linking` cold-start handler is a stub

**Spec mention:** "In `apps/mobile/app/_layout.tsx` use `expo-linking`'s
`useURL()` or `addEventListener('url', ...)` to intercept
`rishimobile://auth/callback?state=...` URLs, parse state, and call
`completeAuthSession` then `authStore.setSession(...)`."

**Reality / decision:**
- `expo-web-browser.openAuthSessionAsync(authUrl, redirectUri)` **resolves
  with the callback URL** when the OS routes the deep link back to the
  app while the browser is still in front. That covers the warm-path
  (99% case) — no `Linking` listener needed.
- For a **cold start** (app was killed when the browser fired the
  redirect), `Linking` would deliver the URL on next launch. We register
  the listener so the scheme is bound, but the handler is a no-op for
  now: there's no in-memory verifier to round-trip with, so the deep
  link is dropped on the floor and the user is back at sign-in.
- Adding cold-start support would require persisting the verifier to
  secure-store before `openAuthSessionAsync` and restoring it on launch.
  Deferred — this is a UX edge case, not a security gap.

---

## 7. `.env` still has `EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY`

**Decision:** left in place. The variable is no longer read by any
source file (`_layout.tsx` doesn't reference it post-1C). Leaving it
in `.env` is harmless and reduces the risk of touching tracked
secrets / development env in this batch. Can be removed in a
follow-up.

---

## 8. iOS `Pods/Local Podspecs/ClerkExpo.podspec.json` left in place

**Reality:** `apps/mobile/ios/Pods` is build output (CocoaPods-generated).
Running `pod install` (or rebuilding the native project) will regenerate
that directory without any Clerk pods. Hand-editing the Pods checkout
would only mask whatever's wrong with the next `pod install`.

**Decision:** ignore. Will get cleaned naturally on the next iOS build.

---

## 9. Out-of-scope parallel work in `apps/mobile/__tests__/rag/`

While Batch 1C was in flight, untracked `__tests__/rag/chunker-{pdf,mobi,
azw3,djvu}.test.ts` files appeared on disk (parallel agent work — see
`.agent-review/`). They are NOT part of Batch 1C and were excluded from
the verification counts via `--testPathIgnorePatterns="__tests__/rag/"`.

Counts reported assume the **same scope as Batch 1B baseline** (149/151
mobile tests).

---

## 10. Verification numbers

Recorded at commit time of Batch 1C's last commit:

| Suite                 | Before 1C       | After 1C       | Delta                  |
| --------------------- | --------------- | -------------- | ---------------------- |
| Mobile jest           | 149/151 (2 pre-existing failures) | 166/168 (same 2 failures) | +17 new tests pass |
| Mobile `tsc --noEmit` | 21 errors (unrelated files)       | 21 errors (unchanged)     | 0 new errors        |
| `@rishi/shared` test  | 21/21           | 34/34          | +13 new shared auth tests |
| Worker test           | 22/22           | 22/22          | unchanged              |
| Mobile `@clerk/*`     | 22 entries      | 0 entries      | fully removed          |

---

## 11. Commit list

| Hash      | Message                                                                  |
| --------- | ------------------------------------------------------------------------ |
| a23ca3d2  | test(shared): add failing tests for shared PKCE + startAuthSession       |
| 02b47d1c  | feat(shared): add portable PKCE + startAuthSession for mobile auth       |
| c1e141f8  | test(mobile): add failing tests for Better-Auth deep-link flow            |
| 924672f8  | feat(mobile): swap auth from Clerk to Better-Auth deep-link flow         |
| 034919c9  | feat(mobile): remove Clerk, wire Better-Auth deep-link sign-in UI        |
