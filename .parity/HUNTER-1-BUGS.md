# Hunter 1 — Loop C Bug Log (auth, sync, api, settings)

Domain: `apps/mobile/{lib/auth,lib/api,lib/api-dev-bypass,lib/sync,lib/stores/authStore,app/(auth),app/(tabs)/settings,lib/file-handler}.ts`, plus `packages/shared/src/{auth,sync,connectivity}/**`.

---

## H1-04 — Returning users hit a blank `/(tabs)` screen because `authHydrated` never flipped

- **Symptom:** A user who cold-starts the app while already signed in (bearer in `expo-secure-store`, user-id in MMKV) sees a blank screen forever. The tabs layout renders `null` because its guard `if (!authHydrated) return null` never un-blocks.
- **File:** `apps/mobile/lib/stores/authStore.ts:hydrateAuth` (sync, no secure-store read, no `authHydrated` flip), `apps/mobile/app/(auth)/_layout.tsx:18-32` (the secure-store check + `setAuthHydrated(true)` lived here, only runs when `/(auth)/_layout.tsx` mounts).
- **Root cause:** expo-router only mounts the route group matching the current URL. A returning user cold-starts onto `/` which matches `/(tabs)`, NOT `/(auth)`. The effect in `(auth)/_layout.tsx` that reads `getSessionToken()` and flips `authHydrated: true` never runs, so the tabs guard hangs indefinitely.
- **Failing tests:** `apps/mobile/__tests__/stores/auth-hydration.test.ts` → four tests covering (a) no-session cold-start, (b) full session restore, (c) MMKV-only orphan user, (d) secure-store rejection still un-blocks the guard.
- **Fix:** Make `hydrateAuth()` async, have it read the bearer from secure-store itself, and set `authHydrated: true` in a `finally` block so the guard always un-blocks. Drop the duplicate effect from `(auth)/_layout.tsx`. Root `_layout.tsx` keeps calling `hydrateAuth()` once at startup; it now properly resolves the auth state for both fresh and returning users.
- **Severity:** High (returning users can't open the app — total blocker for shipping).

---

## H1-03 — `apiClient` 401 cleared secure-store but left `authStore` showing signed-in

- **Symptom:** When the worker returns 401 on any authenticated request, `apiClient` calls `signOut()` (which wipes `expo-secure-store`) and throws. But the in-memory `authStore` still reports `isAuthenticated: true`, `user: {...}`, `sessionToken: <stale>`. The UI keeps treating the user as signed in until something independently calls `hydrateAuth` — every subsequent request now fails with "no session token" while the app still shows the signed-in chrome.
- **File:** `apps/mobile/lib/api.ts:50-53` (only secure-store was cleared, not the store).
- **Root cause:** `signOut()` is a one-liner around `SecureStore.deleteItemAsync` — by design it has no reference to the Zustand store. The 401 branch in `apiClient` must explicitly invoke `useAuthStore.getState().clearSession()` to keep both layers in sync.
- **Failing test:** `apps/mobile/__tests__/api/api-401.test.ts` → `clears the in-memory authStore on 401 (H1-03)`. Two sibling tests pin the baseline (secure-store cleared) and the negative (200 leaves the store untouched).
- **Fix:** In the 401 branch, lazily `require('@/lib/stores/authStore').useAuthStore.getState().clearSession()` after `signOut()`. The lazy require avoids pulling Zustand into modules that mock `@/lib/api` (sync, fallback, realtime tests).
- **Severity:** Medium-high (user-visible auth desync; UI shows signed-in but requests fail silently).

---

## H1-02 — `handleIncomingFile` imported the same URL twice on cold-start

- **Symptom:** When the app cold-starts via an iOS share-sheet action, BOTH `Linking.getInitialURL()` (called inside the `useEffect` in `_layout.tsx`) AND the subsequent `Linking.addEventListener('url')` event fire with the same URL. Each invocation generates a fresh book id, creates a fresh `books/<id>` dir, and calls `service.importFromPath` — the user sees the same book imported twice with two rows in the library.
- **File:** `apps/mobile/lib/file-handler.ts:handleIncomingFile` (no dedup), `apps/mobile/app/_layout.tsx:62-88` (calls handler from both paths).
- **Root cause:** No in-flight dedup. Both code paths in `_layout.tsx` legitimately need to call `handleIncomingFile` (cold-start: only `getInitialURL()` is set; warm boot: only the event fires; cold-start-by-deep-link: BOTH fire). Without a guard at the handler level the duplicate import is unavoidable.
- **Failing test:** `apps/mobile/__tests__/file-handler.test.ts` → `dedupes concurrent calls for the same URL (cold-start + warm-event)` + sibling `allows re-import of the same URL after the first completes`.
- **Fix:** In-flight `Set<string>` keyed by URL. While an import is in-flight, subsequent calls for the same URL return `{ ok: false, reason: 'duplicate-in-flight' }` without generating a book id or invoking the import service. Entries are removed in `finally` so legitimate later re-imports of the same URL are still allowed.
- **Severity:** Medium (visible library duplicates, real data integrity issue).

---

## H1-01 — `handleSignOut` leaked unhandled promise rejection on signOut failure

- **Symptom:** When `lib/auth.signOut()` rejects (e.g. expo-secure-store on a locked device), the `void handleSignOut()` onPress call leaks the rejection out of the React tree as an unhandled-promise-rejection. Trips Sentry noise filters in prod and Jest's unhandledRejection guard in tests (which is why CG09 was `.skip`'d).
- **File:** `apps/mobile/app/(tabs)/settings/index.tsx:64-72`
- **Root cause:** No `try/catch` around `await signOut()` and no `.catch` at the onPress call site. The `try/finally` correctly preserved `clearSession()` in the finally branch, but the rethrow had nowhere to land.
- **Failing test:** `apps/mobile/__tests__/settings/settings.test.tsx` → `Sign-out still clears the auth store when lib/auth.signOut throws` (was `.skip`'d before fix, now passing).
- **Fix:** Catch the rejection inside `handleSignOut` and `console.warn` the error. `clearSession()` still runs in the `finally`. Test unskipped.
- **Severity:** Low (UX-only, no data integrity impact)
