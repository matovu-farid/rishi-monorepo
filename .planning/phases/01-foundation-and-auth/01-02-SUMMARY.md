---
phase: 01-foundation-and-auth
plan: 02
subsystem: auth
tags: [clerk, jwt, expo-secure-store, react-native, token-exchange, api-client]

# Dependency graph
requires:
  - phase: 01-foundation-and-auth/01
    provides: "Clerk sign-in screen with useAuth hooks"
provides:
  - "Token exchange service (Clerk session -> Worker JWT)"
  - "Secure token storage via expo-secure-store"
  - "Authenticated API client with 401 auto-refresh"
  - "Home screen with user info and Worker health check"
affects: [02-book-management, 03-reading-experience, 04-ai-features]

# Tech tracking
tech-stack:
  added: [expo-secure-store]
  patterns: [token-exchange, api-client-init-pattern, secure-store-with-expiry-buffer]

key-files:
  created:
    - apps/mobile/lib/auth.ts
    - apps/mobile/lib/api.ts
  modified:
    - apps/mobile/app/(tabs)/_layout.tsx
    - apps/mobile/app/(tabs)/index.tsx
    - apps/mobile/.env

key-decisions:
  - "initApiClient pattern: pass getToken from useAuth hook to avoid hooks-in-non-component code"
  - "5-minute expiry buffer on Worker JWT to proactively refresh before 401"
  - "Single retry on 401: clear JWT, re-exchange via Clerk, retry once then throw"

patterns-established:
  - "Token exchange: Clerk session token -> POST /api/auth/exchange -> Worker JWT in SecureStore"
  - "API client init: initApiClient(getToken) called in authenticated layout useEffect"
  - "Sign out: clearWorkerToken() then signOut() then navigate to sign-in"

requirements-completed: [AUTH-02, AUTH-03, AUTH-04]

# Metrics
duration: 2min
completed: 2026-04-05
status: checkpoint-pending
---

# Phase 01 Plan 02: Mobile Auth Token Exchange Summary

**Clerk-to-Worker JWT exchange with secure storage and auto-refreshing API client**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-05T15:07:50Z
- **Completed:** PENDING (checkpoint:human-verify awaiting)
- **Tasks:** 3 of 4 (Task 4 is human verification checkpoint)
- **Files modified:** 5

## Accomplishments
- Token exchange service that converts Clerk session tokens to Worker JWTs stored in expo-secure-store
- API client with automatic JWT attachment and single-retry on 401 (clear + re-exchange + retry)
- Home screen showing user info from Clerk and Worker API health status
- Sign-out flow clearing both Clerk session and Worker JWT

## Task Commits

Each task was committed atomically:

1. **Task 1: Create auth service for token exchange and secure storage** - `9d5a84e` (feat)
2. **Task 2: Create API client with automatic token refresh on 401** - `8b0d0d4` (feat)
3. **Task 3: Wire API client into app with proof-of-life health check** - `b836b95` (feat)

**Task 4:** checkpoint:human-verify -- awaiting user verification of end-to-end auth flow

## Files Created/Modified
- `apps/mobile/lib/auth.ts` - Token exchange (exchangeToken), secure retrieval (getWorkerToken), cleanup (clearWorkerToken)
- `apps/mobile/lib/api.ts` - Authenticated fetch wrapper with initApiClient and apiClient exports
- `apps/mobile/app/(tabs)/_layout.tsx` - Added initApiClient(getToken) in useEffect on sign-in
- `apps/mobile/app/(tabs)/index.tsx` - New home screen with user info, health check, sign-out
- `apps/mobile/.env` - Added EXPO_PUBLIC_WORKER_URL

## Decisions Made
- Used initApiClient pattern to bridge React hooks (useAuth) with non-component lib code
- 5-minute expiry buffer prevents most 401s by refreshing before token expires
- Single retry on 401 to avoid infinite loops; throws if retry fails

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required

External services require manual configuration:
- Set `EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY` in `apps/mobile/.env` to actual Clerk publishable key
- Set `EXPO_PUBLIC_WORKER_URL` in `apps/mobile/.env` to deployed Worker URL
- Enable "Native Applications" in Clerk Dashboard -> Sessions
- Build custom dev client: `cd apps/mobile && npx expo prebuild && npx expo run:ios`

## Next Phase Readiness
- Auth chain complete: sign-in -> token exchange -> authenticated API calls
- Awaiting human verification (Task 4) before marking plan complete
- Ready for Phase 02 (book management) once verified

---
*Phase: 01-foundation-and-auth*
*Completed: 2026-04-05 (pending checkpoint)*
