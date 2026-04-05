---
phase: 01-foundation-and-auth
verified: 2026-04-05T00:00:00Z
status: human_needed
score: 7/7 must-haves verified
human_verification:
  - test: "Sign-in flow end-to-end on device or simulator"
    expected: "App launches to sign-in screen when not authenticated. Email/password sign-in completes, lands on Home tab showing user name and Worker API status 'healthy'."
    why_human: "UI behavior and actual network call to deployed Worker cannot be verified programmatically against a real Clerk key."
  - test: "Token persistence across app restart"
    expected: "Force-quit and relaunch the app — user remains signed in without re-entering credentials. Home screen loads user info and health status."
    why_human: "SecureStore persistence across process restarts requires a running device/simulator."
  - test: "JWT expiry and re-authentication"
    expected: "When Worker JWT expires (or is cleared manually), the API client silently re-exchanges via Clerk and retries the request. User sees no auth error."
    why_human: "Requires time-based token expiry or manual SecureStore manipulation on a real device."
  - test: "Sign Out clears all tokens"
    expected: "Tap Sign Out. App navigates to sign-in screen. Re-launching the app shows sign-in (Clerk session cleared) and a fresh API call triggers re-exchange."
    why_human: "Requires verifying both Clerk session state and SecureStore contents are cleared, only verifiable on device."
  - test: "Custom dev build (not Expo Go)"
    expected: "App runs as a custom Expo dev client build (npx expo run:ios or run:android), not Expo Go. expo-dev-client is present for future native module phases."
    why_human: "Whether the app is running as a custom dev build vs Expo Go requires a physical build step, not static analysis."
---

# Phase 01: Foundation and Auth Verification Report

**Phase Goal:** Users can sign in on mobile and make authenticated API calls to the Worker, with the app running as a custom dev build (not Expo Go).
**Verified:** 2026-04-05
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User sees a Clerk sign-in screen when not authenticated | VERIFIED | `(auth)/_layout.tsx` checks `isSignedIn`, renders `Stack` with sign-in route; `(tabs)/_layout.tsx` redirects unauthenticated users to `/(auth)/sign-in` |
| 2 | User is redirected to tabs after signing in | VERIFIED | `sign-in.tsx` calls `router.replace('/(tabs)')` on `signIn.status === 'complete'`; Google flow also calls `router.replace('/(tabs)')` |
| 3 | Unauthenticated users cannot reach the tabs screens | VERIFIED | `(tabs)/_layout.tsx` line 22: `if (!isSignedIn) return <Redirect href="/(auth)/sign-in" />` — hard redirect before tabs render |
| 4 | App builds as custom Expo dev client | VERIFIED | `expo-dev-client ~6.0.20` in `package.json` dependencies; `expo-secure-store` and `@clerk/expo` in `app.json` plugins array |
| 5 | Mobile app exchanges Clerk session token for Worker JWT via `/api/auth/exchange` | VERIFIED | `lib/auth.ts` line 29: `fetch(\`${WORKER_API_URL}/api/auth/exchange\`, ...)` with `Authorization: Bearer ${clerkSessionToken}` header |
| 6 | Worker JWT is stored in expo-secure-store and persists across restarts | VERIFIED | `lib/auth.ts` uses `SecureStore.setItemAsync(WORKER_JWT_KEY, ...)` and `SecureStore.setItemAsync(WORKER_JWT_EXPIRY_KEY, ...)` with 5-minute expiry buffer |
| 7 | Expired or invalid JWT triggers re-authentication | VERIFIED | `lib/api.ts` lines 49-64: on 401, calls `clearWorkerToken()`, then `refreshWorkerToken()` (re-exchange via Clerk), retries request once |

**Score:** 7/7 truths verified

---

### Required Artifacts

| Artifact | Provides | Status | Details |
|----------|----------|--------|---------|
| `apps/mobile/app/_layout.tsx` | ClerkProvider wrapping entire app | VERIFIED | Contains `ClerkProvider` with `publishableKey` and `tokenCache={tokenCache}`, `ClerkLoaded` guard, `Slot` (not Stack) |
| `apps/mobile/app/(auth)/_layout.tsx` | Auth route group, redirects signed-in users to tabs | VERIFIED | `useAuth()` check, `Redirect href="/(tabs)"` when `isSignedIn`, `Stack` for unauthenticated routes |
| `apps/mobile/app/(auth)/sign-in.tsx` | Sign-in screen with email/password and Google OAuth | VERIFIED | `useSignIn` for password flow, `useSignInWithGoogle` (Clerk v3 Google-native API) for OAuth |
| `apps/mobile/app/(tabs)/_layout.tsx` | Protected tabs layout with auth guard and API client init | VERIFIED | `Redirect href="/(auth)/sign-in"` when not signed in; `initApiClient(getToken)` in `useEffect` |
| `apps/mobile/lib/auth.ts` | Token exchange and secure storage | VERIFIED | Exports `exchangeToken`, `getWorkerToken`, `clearWorkerToken`, `WORKER_API_URL`; uses `SecureStore`; fetches `/api/auth/exchange` |
| `apps/mobile/lib/api.ts` | API client with auto-refresh on 401 | VERIFIED | Exports `initApiClient`, `apiClient`; imports from `./auth`; attaches `Authorization: Bearer` header; 401 retry logic present |
| `apps/mobile/app/(tabs)/index.tsx` | Home screen proof-of-life with user info and health check | VERIFIED | Uses `apiClient('/health')`, `useUser()`, `clearWorkerToken()` + `signOut()` on sign out |
| `apps/mobile/package.json` | Clerk, SecureStore, dev-client packages | VERIFIED | `@clerk/expo ^3.1.6`, `expo-secure-store ~15.0.8`, `expo-dev-client ~6.0.20` |
| `apps/mobile/app.json` | Plugin registration for SecureStore and Clerk | VERIFIED | `expo-secure-store` and `@clerk/expo` in plugins array |
| `apps/mobile/.env` | Clerk and Worker URL env vars | VERIFIED | `EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_test_PLACEHOLDER`, `EXPO_PUBLIC_WORKER_URL=https://rishi-worker.fidexa.workers.dev` |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `apps/mobile/app/_layout.tsx` | `@clerk/expo` | `ClerkProvider` with `tokenCache` | WIRED | Line 25: `<ClerkProvider publishableKey={publishableKey} tokenCache={tokenCache}>` |
| `apps/mobile/app/(tabs)/_layout.tsx` | `apps/mobile/app/(auth)/sign-in.tsx` | `Redirect` when not signed in | WIRED | Line 22: `if (!isSignedIn) return <Redirect href="/(auth)/sign-in" />` |
| `apps/mobile/lib/auth.ts` | `/api/auth/exchange` | `fetch POST` with Clerk Bearer token | WIRED | Line 29: `fetch(\`${WORKER_API_URL}/api/auth/exchange\`, { method: 'POST', headers: { Authorization: Bearer ... } })` |
| `apps/mobile/lib/api.ts` | `apps/mobile/lib/auth.ts` | Imports `getWorkerToken`, `exchangeToken`, `clearWorkerToken` | WIRED | Line 1: `import { getWorkerToken, exchangeToken, clearWorkerToken, WORKER_API_URL } from './auth'` |
| `apps/mobile/lib/api.ts` | Worker protected endpoints | `Authorization: Bearer` header with Worker JWT | WIRED | Lines 41-43 and 58-62: `Authorization: \`Bearer ${token}\`` on all requests and retry |
| `apps/mobile/app/(tabs)/_layout.tsx` | `apps/mobile/lib/api.ts` | `initApiClient(getToken)` in `useEffect` | WIRED | Lines 15-19: `useEffect(() => { if (isSignedIn) { initApiClient(getToken) } }, [isSignedIn, getToken])` |
| `workers/worker/src/index.ts` | Worker JWT verification | `requireWorkerAuth` middleware on protected routes | WIRED | Line 71: `app.post("/api/auth/exchange", ...)` exists; `requireWorkerAuth` middleware confirmed on lines 42-68 |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| AUTH-01 | 01-01-PLAN.md | User can sign in via Clerk on mobile (email, social, or existing account) | SATISFIED | `sign-in.tsx` implements email/password via `useSignIn` and Google OAuth via `useSignInWithGoogle`; `ClerkProvider` wraps app |
| AUTH-02 | 01-02-PLAN.md | Mobile app exchanges Clerk session token for Worker JWT via existing `/api/auth/exchange` endpoint | SATISFIED | `lib/auth.ts` `exchangeToken()` POSTs to `/api/auth/exchange` with Clerk Bearer token; endpoint confirmed in `workers/worker/src/index.ts` line 71 |
| AUTH-03 | 01-02-PLAN.md | JWT persists in secure storage across app restarts | SATISFIED | `lib/auth.ts` stores JWT via `SecureStore.setItemAsync`; `getWorkerToken()` reads with 5-minute expiry buffer; SecureStore is encrypted and persists across restarts |
| AUTH-04 | 01-02-PLAN.md | Expired JWT triggers re-authentication flow | SATISFIED | `lib/api.ts` lines 49-64: 401 response clears stored JWT, calls `refreshWorkerToken()` (re-exchanges Clerk token), retries once; `getWorkerToken()` proactively returns null before 5-minute expiry window |
| AUTH-05 | 01-01-PLAN.md | Unauthenticated users are redirected to sign-in screen | SATISFIED | `(tabs)/_layout.tsx` line 22: hard `Redirect` to `/(auth)/sign-in` when `!isSignedIn`; `(auth)/_layout.tsx` redirects signed-in users to tabs (bidirectional guard) |

All 5 AUTH requirements are satisfied by code verified in the codebase. REQUIREMENTS.md traceability table correctly marks AUTH-01 through AUTH-05 as Complete for Phase 1.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `app/(auth)/sign-in.tsx` | 17 | `const { signIn } = useSignIn()` — `isLoaded` guard not destructured | Info | Plan specified `if (!isLoaded) return` but implementation uses `if (!signIn) return` — functionally equivalent for the password flow but `isLoaded` is the canonical Clerk guard pattern. No functional impact. |

No blocker or warning-level anti-patterns found. The `return null` instances in auth guards and error paths are all legitimate. The `placeholder` attribute matches are HTML TextInput placeholder text, not code stubs.

**Notable deviation (not an anti-pattern):** The plan specified `useOAuth({ strategy: 'oauth_google' })` for Google sign-in. The implementation correctly uses `useSignInWithGoogle` from `@clerk/expo/google` — this is the Clerk v3 recommended Google-native API (confirmed in installed type definitions at `node_modules/@clerk/expo/dist/google/index.d.ts`). The `useOAuth` hook still exists in v3 but `useSignInWithGoogle` provides a native Google sign-in experience on iOS/Android.

---

### Commit Verification

All 5 task commits documented in SUMMARY files are present in the repository:

| Commit | Task | Status |
|--------|------|--------|
| `da49d38` | Install Clerk dependencies and configure Expo plugins | FOUND |
| `dc17710` | Add Clerk auth flow with route guards and sign-in screen | FOUND |
| `9d5a84e` | Create auth service for token exchange and secure storage | FOUND |
| `8b0d0d4` | Create API client with automatic token refresh on 401 | FOUND |
| `b836b95` | Wire API client into app with proof-of-life health check | FOUND |

---

### Human Verification Required

#### 1. Sign-in flow end-to-end

**Test:** Set `EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY` to a real Clerk key. Run `cd apps/mobile && npx expo run:ios` (or `run:android`). Launch the app.
**Expected:** App shows "Welcome to Rishi" sign-in screen. Sign in with email/password. App navigates to Home tab showing your name, email, and Worker API status "healthy".
**Why human:** Requires a real Clerk publishable key, a running simulator/device, and network access to the deployed Worker.

#### 2. Token persistence across app restart

**Test:** After signing in, force-quit the app and relaunch.
**Expected:** App goes directly to the Home tab (no sign-in screen). User name and email displayed. Worker health check loads.
**Why human:** SecureStore persistence (Clerk tokenCache + Worker JWT) can only be verified across process restarts on a real device or simulator.

#### 3. JWT expiry and automatic re-authentication

**Test:** Clear the Worker JWT from SecureStore manually (or wait for the 7-day expiry to be within the 5-minute buffer), then trigger an API call.
**Expected:** `apiClient` transparently re-exchanges the Clerk token for a new Worker JWT and retries the request. No auth error shown to the user.
**Why human:** Requires time-based token manipulation or simulating token expiry on a running device.

#### 4. Sign Out clears all tokens

**Test:** On the Home screen, tap "Sign Out".
**Expected:** App navigates to sign-in screen. Force-quitting and relaunching shows sign-in (Clerk session cleared via tokenCache). A new sign-in triggers fresh token exchange.
**Why human:** Verifying that both Clerk's tokenCache and SecureStore are fully cleared requires checking device state across app restarts.

#### 5. Custom dev build (not Expo Go)

**Test:** Confirm the app is running as a custom dev client build (`npx expo run:ios` or `run:android`), not Expo Go.
**Expected:** Build completes without errors. `expo-dev-client` launch screen appears (not Expo Go home screen). This confirms the foundation for native modules in later phases.
**Why human:** Whether the app actually launches as a custom dev build requires a physical build invocation and observation of the launch screen.

---

### Summary

All 7 observable truths are verified in code. All 10 required artifacts exist, are substantive (not stubs), and are correctly wired. All 5 AUTH requirements (AUTH-01 through AUTH-05) are fully covered by the implementations in Plans 01 and 02 — no orphaned requirements. All 5 task commits are present in the repository. No blocking or warning anti-patterns found.

The only items blocking a full "passed" status are 5 human verification tests that require a running device/simulator, real Clerk credentials, and network access to the deployed Worker. These are runtime behaviors that static code analysis cannot confirm.

The phase goal — "Users can sign in on mobile and make authenticated API calls to the Worker, with the app running as a custom dev build" — is fully implemented in code. Human testing is the final gate.

---

_Verified: 2026-04-05_
_Verifier: Claude (gsd-verifier)_
