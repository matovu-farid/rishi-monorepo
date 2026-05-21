# Hunter 1 — Loop C Bug Log (auth, sync, api, settings)

Domain: `apps/mobile/{lib/auth,lib/api,lib/api-dev-bypass,lib/sync,lib/stores/authStore,app/(auth),app/(tabs)/settings,lib/file-handler}.ts`, plus `packages/shared/src/{auth,sync,connectivity}/**`.

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
