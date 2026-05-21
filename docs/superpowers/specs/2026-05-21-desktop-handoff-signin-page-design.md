# Desktop-Handoff Sign-In Page Design

**Date:** 2026-05-21
**Status:** Draft — awaiting user review

## Problem

After the desktop app hands off to the web sign-in flow and the user successfully signs in, the web page (`/sign-in`) continues to render the sign-in form while a small toast in the bottom-right corner says "Signed in — Return to the Rishi app to continue. You can close this tab." Users see a prominent sign-in widget alongside a tiny success notification and assume the sign-in failed.

The bug is most visible after the Google OAuth flow, because the worker's `web_url` points at `/sign-in?login=true&provider=google&state=...`, and Better Auth's `signIn.social` is configured with `callbackURL: window.location.href`. After Google completes, the user lands back on `/sign-in?login=true&state=...` with an active session — but the page has no session-aware logic and renders the form regardless.

## Goals

- Signed-in users in the desktop-handoff flow see a clear "Return to the Rishi app" page instead of the sign-in form.
- The page surfaces the actual handoff state: `completing`, `done`, `error`.
- Signed-in users who land on `/sign-in` outside the desktop flow are redirected to `returnTo` (default `/`).
- The bottom-right toast remains for non-`/sign-in` pages (specifically the magic-link callback that lands on `/?login=true&state=...`).

## Non-Goals

- No backend / worker changes. The magic-link `callbackURL` continues to point at `/`.
- No change to the sign-in form itself (email / Google / passkey).
- No change to the `/desktop/start`, `/desktop/start/complete`, or `/desktop/poll` worker endpoints.

## Current Flow (for reference)

| Flow | URL the user lands on after auth | Owner of post-sign-in UI |
|---|---|---|
| Magic link | `/?login=true&state=<uuid>` | `DesktopHandoffListener` toast (global) |
| Google OAuth | `/sign-in?login=true&state=<uuid>` | `DesktopHandoffListener` toast **+ sign-in form (bug)** |
| Plain web sign-in | `/sign-in` then `returnTo` | Sign-in page form (no redirect after session — see Goals) |

## Design

### Architecture

Three pieces:

1. **`useDesktopHandoff()`** — new hook in `apps/web/src/lib/use-desktop-handoff.ts`. Owns the handoff state machine. Both the sign-in page and the global toast consume it. Dedupes the POST to `/desktop/start/complete` by `state` via a module-level `Map<string, Promise<void>>`.
2. **`DesktopHandoffListener`** — existing component, refactored to consume the hook and return `null` on `/sign-in`.
3. **`/sign-in` page** — refactored to branch on session state and handoff state.

### `useDesktopHandoff` contract

```ts
type HandoffStatus = "inactive" | "waiting" | "completing" | "done" | "error"

interface HandoffResult {
  isDesktopFlow: boolean
  status: HandoffStatus
  errorMsg: string
}

export function useDesktopHandoff(): HandoffResult
```

State transitions:

- `inactive` — URL has no `?login=true&state=<uuid>` (or `state` is malformed).
- `waiting` — desktop params present, session not yet established.
- `completing` — session established, POST to `/desktop/start/complete` in flight.
- `done` — POST succeeded.
- `error` — POST failed; `errorMsg` populated.

Dedupe: a module-level `Map<string, Promise<void>>` keyed by `state`. The first consumer to reach `completing` writes the in-flight promise; the second consumer awaits the same promise. Both observers transition to `done`/`error` together.

### `DesktopHandoffListener` (refactored)

```tsx
export function DesktopHandoffListener() {
  const pathname = usePathname()
  const { isDesktopFlow, status, errorMsg } = useDesktopHandoff()

  if (pathname === "/sign-in") return null
  if (!isDesktopFlow) return null
  if (status === "inactive" || status === "waiting") return null

  // Render the existing 3-state toast (completing / done / error) at bottom-right.
}
```

Behavior changes:

- No longer owns the POST — delegated to the hook.
- Returns `null` on `/sign-in` (the page renders the full-screen card instead).
- Still mounted globally in `layout.tsx`. No change to its position in the tree.

### `/sign-in` page (refactored)

```tsx
function SignInPageInner() {
  const router = useRouter()
  const params = useSearchParams()
  const returnTo = params.get("returnTo") ?? "/"
  const { data: session, isPending } = useSession()
  const handoff = useDesktopHandoff()

  // existing ?provider=google auto-kick effect — unchanged

  // Web flow: signed in but not a desktop handoff → bounce home
  useEffect(() => {
    if (isPending) return
    if (!session) return
    if (handoff.isDesktopFlow) return
    router.replace(returnTo)
  }, [isPending, session, handoff.isDesktopFlow, returnTo, router])

  if (isPending) return <SignInSkeleton />
  if (session && handoff.isDesktopFlow) {
    return <DesktopReturnPanel status={handoff.status} errorMsg={handoff.errorMsg} />
  }
  if (session) return <SignInSkeleton />   // brief skeleton before router.replace lands

  return <SignInForm ... />   // existing form, extracted into a local component for clarity
}
```

`<DesktopReturnPanel>` is a local component in the same file. Centered card, same vertical rhythm as the form (`max-w-md mx-auto py-20`). States:

- **`completing`** — heading "Completing sign-in…" + spinner.
- **`done`** — heading "You're signed in" + paragraph "Return to the Rishi app to continue. You can close this tab."
- **`error`** — heading "Sign-in handoff failed" (destructive color) + `errorMsg` + a "Try again" link that re-renders the page with the same query params (effectively retries the POST by clearing the dedupe entry for this `state`; see below).

For the "Try again" affordance: the dedupe map exposes a `clearHandoff(state: string)` helper that removes the cached promise. The button calls it and then triggers a re-render (forced state bump) so the hook re-fires the POST.

### Data flow

```
Desktop opens /sign-in?login=true&state=abc&provider=google
    ↓
SignInPage mounts → ?provider=google effect → signIn.social(...)
    ↓
Google OAuth roundtrip → callbackURL: /sign-in?login=true&state=abc
    ↓
SignInPage mounts again → useSession() returns { data: session }
    ↓
useDesktopHandoff() detects state=abc, session present
    → status: "completing"
    → POST /desktop/start/complete { state: "abc" } (creditentials: include)
    → status: "done"
    ↓
<DesktopReturnPanel status="done"> renders full-page
    ↓
Desktop poller picks up the result from Redis → desktop closes the browser flow
```

### Error handling

| Failure | Handling |
|---|---|
| POST returns non-2xx | `status` → `error`, `errorMsg` set to `"handoff failed (<code>): <body>"` (existing message format). `<DesktopReturnPanel>` renders the error state with a "Try again" button. |
| Network error during POST | Same as above, `errorMsg` set to the thrown message. |
| Session never lands (e.g., user closes Google popup) | `status` stays `waiting`. Sign-in form does *not* render (we're still showing the skeleton on `isPending`, but once `isPending` resolves with `session = null` and `handoff.isDesktopFlow = true && handoff.status === "waiting"`, we fall through to the form so the user can try again). |
| `state` query param malformed | `isDesktopFlow` is `false`. Page behaves like the plain web flow. |

### Testing strategy

Tests live in `apps/web` and follow the existing Jest + React Testing Library convention.

**`apps/web/src/lib/use-desktop-handoff.test.ts`**
1. No `state` param → `isDesktopFlow: false`, `status: "inactive"`.
2. `state` present, no session → `status: "waiting"`, POST not called.
3. `state` present, session arrives → `status: "completing"` → `"done"`, POST called once.
4. Two hook consumers with same `state` → POST called exactly once (dedupe verified).
5. POST returns 500 → `status: "error"`, `errorMsg` populated.
6. Network error → `status: "error"`, `errorMsg` populated.
7. `clearHandoff(state)` then re-fire → POST called again (retry path).

**`apps/web/src/app/sign-in/page.test.tsx`**
1. Not signed in, no desktop params → form renders.
2. Not signed in, `?provider=google` → `signIn.social` called.
3. Signed in, `?login=true&state=abc`, handoff `completing` → spinner, no form.
4. Signed in, `?login=true&state=abc`, handoff `done` → "Return to the Rishi app" card, no form.
5. Signed in, `?login=true&state=abc`, handoff `error` → error panel with "Try again".
6. Signed in, no desktop params → `router.replace("/")` called.
7. Signed in, no desktop params, `?returnTo=/library` → `router.replace("/library")`.
8. `isPending` → skeleton, no form, no redirect.

**`apps/web/src/components/desktop-handoff-listener.test.tsx`**
1. `pathname = "/sign-in"` → returns `null` even with valid handoff params.
2. `pathname = "/"`, handoff `done` → renders toast.
3. `pathname = "/"`, no desktop params → returns `null`.

Mocks:
- `useSession` from `@/lib/auth-client`
- `useRouter`, `usePathname`, `useSearchParams` from `next/navigation`
- `fetch` for the handoff POST (verify call count for dedupe assertion)

### Files touched

| File | Action |
|---|---|
| `apps/web/src/lib/use-desktop-handoff.ts` | **New** |
| `apps/web/src/components/desktop-handoff-listener.tsx` | Modified — consume hook, suppress on `/sign-in` |
| `apps/web/src/app/sign-in/page.tsx` | Modified — session-aware branching, new `<DesktopReturnPanel>` |
| `apps/web/src/lib/use-desktop-handoff.test.ts` | **New** |
| `apps/web/src/app/sign-in/page.test.tsx` | **New** |
| `apps/web/src/components/desktop-handoff-listener.test.tsx` | **New** |

No backend / worker changes. No `apps/rishi-electron` or `apps/rishi-tauri` changes.

## Risks & Mitigations

- **Risk:** Dedupe map persists across navigations within the same browser tab. If a user retries the desktop flow with a *new* `state` value, the old entry stays in memory. **Mitigation:** Acceptable. The map is keyed by `state` (a uuid per attempt), so stale entries are harmless. They GC when the tab closes.
- **Risk:** Hook fires POST during SSR / hydration mismatch. **Mitigation:** The hook is `"use client"` and gates the POST on `useSession()` returning a value, which is client-only.
- **Risk:** A signed-in user who came from desktop dismisses the page mid-flow (closes tab) before the POST completes. **Mitigation:** No change from today. Desktop poller times out at 10 minutes (`POLL_TIMEOUT_MS` in `auth-service.ts`).
- **Risk:** The "brief skeleton before `router.replace` lands" path on the plain-web flow could flash for a frame. **Mitigation:** Acceptable. The redirect is synchronous after `useEffect` and the skeleton is invisible-ish (blank box). Could revisit if QA flags it.
