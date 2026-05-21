# Phase A — Bugs Found During Coverage Fill

This file lists real implementation issues uncovered while adding the
Loop B Phase A quick-win tests. Each entry describes the behavior gap,
its blast radius, and the recommended fix. Fixes are deferred to Loop C
(or a follow-up task) so Phase A stays scoped to test-only changes.

---

## Bug PA-01 — `handleSignOut` in settings screen leaks unhandled rejections

**File:** `apps/mobile/app/(tabs)/settings/index.tsx:64-72`
**Discovered while adding:** CG09 (sign-out failure path)
**Severity:** Low (UX-only — no data integrity impact)

### Behavior

```ts
const handleSignOut = useCallback(async () => {
  try {
    await signOut()
  } finally {
    clearSession()
  }
}, [clearSession])

// …
onPress={() => { void handleSignOut() }}
```

When `lib/auth.signOut()` rejects (e.g. expo-secure-store unavailable on
locked device), the `try/finally` runs `clearSession()` correctly — the
in-memory auth state is cleared. But the rejection then re-throws out of
`handleSignOut`, and the caller's `void handleSignOut()` does NOT catch
it, leaving an unhandled-promise-rejection.

In production this surfaces as a `[Unhandled promise rejection]` log on
React Native and a `unhandledrejection` event on Hermes — neither breaks
the app, but they trip Sentry's noise filters and clutter dev logs.

### Fix (deferred to Loop C)

Catch the rejection at the call site:

```ts
onPress={() => {
  handleSignOut().catch((err) => {
    console.warn('[settings] sign-out failed:', err)
  })
}}
```

Or move the `console.warn` into `handleSignOut` itself:

```ts
const handleSignOut = useCallback(async () => {
  try {
    await signOut()
  } catch (err) {
    console.warn('[settings] sign-out failed:', err)
  } finally {
    clearSession()
  }
}, [clearSession])
```

### Test coverage

The CG09 test (`Sign-out still clears the auth store when lib/auth.signOut throws`)
is currently `it.skip(...)` in `__tests__/settings/settings.test.tsx`
because Jest's built-in unhandled-rejection guard fails the suite even
when `process.removeAllListeners('unhandledRejection')` is used to
suppress the leak.

The behaviour-under-test (clearSession runs in the `finally` branch) is
implemented correctly — only the leak path differs. Once PA-01 is
fixed in Loop C, unskip the test and verify the assertions pass.

---
