---
phase: 01-foundation-and-auth
plan: 01
subsystem: auth
tags: [clerk, expo, react-native, oauth, authentication, route-guards]

# Dependency graph
requires: []
provides:
  - ClerkProvider wrapping entire mobile app with tokenCache
  - Auth route group with sign-in screen (email/password + Google OAuth)
  - Protected tabs route group with auth redirect guard
  - expo-dev-client installed for custom dev builds
affects: [01-02, mobile-sync, mobile-api]

# Tech tracking
tech-stack:
  added: ["@clerk/expo", "expo-secure-store", "expo-dev-client"]
  patterns: ["ClerkProvider + tokenCache at root", "Route group auth guards with useAuth + Redirect", "Custom sign-in flow with useSignIn + useOAuth"]

key-files:
  created:
    - apps/mobile/app/(auth)/_layout.tsx
    - apps/mobile/app/(auth)/sign-in.tsx
    - apps/mobile/.env
  modified:
    - apps/mobile/app/_layout.tsx
    - apps/mobile/app/(tabs)/_layout.tsx
    - apps/mobile/package.json
    - apps/mobile/app.json

key-decisions:
  - "Used Slot instead of Stack in root layout to let route groups manage their own navigation"
  - "Custom sign-in UI with useSignIn/useOAuth hooks instead of pre-built Clerk components for full styling control"

patterns-established:
  - "Auth guard pattern: useAuth() check with Redirect in route group layouts"
  - "Root provider pattern: ClerkProvider > ClerkLoaded > ThemeProvider > Slot"

requirements-completed: [AUTH-01, AUTH-05]

# Metrics
duration: 5min
completed: 2026-04-05
---

# Phase 01 Plan 01: Mobile Clerk Auth Setup Summary

**Clerk auth SDK with email/password + Google OAuth sign-in, route group guards protecting tabs, and expo-dev-client for native builds**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-05T14:59:13Z
- **Completed:** 2026-04-05T15:04:06Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments
- Installed @clerk/expo, expo-secure-store, and expo-dev-client with Expo plugin configuration
- Created sign-in screen with email/password and Google OAuth flows
- Added bidirectional auth guards: (auth) redirects signed-in users to tabs, (tabs) redirects unauthenticated users to sign-in

## Task Commits

Each task was committed atomically:

1. **Task 1: Install Clerk dependencies and configure app.json plugins** - `da49d38` (feat)
2. **Task 2: Wrap root layout in ClerkProvider and restructure routes with auth guards** - `dc17710` (feat)

## Files Created/Modified
- `apps/mobile/app/_layout.tsx` - Root layout with ClerkProvider, ClerkLoaded, tokenCache, Slot
- `apps/mobile/app/(auth)/_layout.tsx` - Auth route group layout, redirects signed-in users to tabs
- `apps/mobile/app/(auth)/sign-in.tsx` - Sign-in screen with email/password and Google OAuth
- `apps/mobile/app/(tabs)/_layout.tsx` - Protected tabs layout, redirects unauthenticated users to sign-in
- `apps/mobile/package.json` - Added @clerk/expo, expo-secure-store, expo-dev-client
- `apps/mobile/app.json` - Added expo-secure-store and @clerk/expo to plugins array
- `apps/mobile/.env` - Placeholder Clerk publishable key

## Decisions Made
- Used Slot instead of Stack in root layout so route groups manage their own navigation stacks
- Custom sign-in UI with useSignIn/useOAuth hooks instead of Clerk pre-built components for full NativeWind styling control
- Placed expo-secure-store and @clerk/expo before expo-splash-screen in plugins array (order from plan)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Installed node_modules before running expo install**
- **Found during:** Task 1
- **Issue:** node_modules did not exist -- expo install requires the expo module to be installed locally
- **Fix:** Ran `npm install` first to bootstrap dependencies, then ran `npx expo install` for the new packages
- **Files modified:** apps/mobile/node_modules/ (not committed), apps/mobile/package-lock.json
- **Verification:** expo install completed successfully, all packages in package.json
- **Committed in:** da49d38 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Required dependency bootstrap before expo install could run. No scope creep.

## Issues Encountered
None beyond the node_modules bootstrap noted above.

## User Setup Required
Replace `pk_test_PLACEHOLDER` in `apps/mobile/.env` with actual Clerk publishable key from the Clerk dashboard.

## Next Phase Readiness
- Auth foundation complete: ClerkProvider, route guards, sign-in screen all in place
- Ready for Plan 02 (token exchange with Worker API) which builds on this auth foundation
- expo-dev-client installed, enabling custom dev builds needed for native modules in later phases

---
*Phase: 01-foundation-and-auth*
*Completed: 2026-04-05*
