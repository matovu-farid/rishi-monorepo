# Hunter 1 — Loop C Bug Log (auth, sync, api, settings)

Domain: `apps/mobile/{lib/auth,lib/api,lib/api-dev-bypass,lib/sync,lib/stores/authStore,app/(auth),app/(tabs)/settings,lib/file-handler}.ts`, plus `packages/shared/src/{auth,sync,connectivity}/**`.

---

## H1-01 — `handleSignOut` leaked unhandled promise rejection on signOut failure

- **Symptom:** When `lib/auth.signOut()` rejects (e.g. expo-secure-store on a locked device), the `void handleSignOut()` onPress call leaks the rejection out of the React tree as an unhandled-promise-rejection. Trips Sentry noise filters in prod and Jest's unhandledRejection guard in tests (which is why CG09 was `.skip`'d).
- **File:** `apps/mobile/app/(tabs)/settings/index.tsx:64-72`
- **Root cause:** No `try/catch` around `await signOut()` and no `.catch` at the onPress call site. The `try/finally` correctly preserved `clearSession()` in the finally branch, but the rethrow had nowhere to land.
- **Failing test:** `apps/mobile/__tests__/settings/settings.test.tsx` → `Sign-out still clears the auth store when lib/auth.signOut throws` (was `.skip`'d before fix, now passing).
- **Fix:** Catch the rejection inside `handleSignOut` and `console.warn` the error. `clearSession()` still runs in the `finally`. Test unskipped.
- **Severity:** Low (UX-only, no data integrity impact)
