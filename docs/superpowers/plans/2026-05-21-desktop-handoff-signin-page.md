# Desktop-Handoff Sign-In Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop showing the sign-in form on `/sign-in` when the user is already signed in. In the desktop-handoff flow, show a full-page "Return to the Rishi app" panel that reflects actual handoff status. In the plain-web flow, redirect to `returnTo`.

**Architecture:** Extract a shared `useDesktopHandoff()` hook that owns the URL detection + session check + POST to `/desktop/start/complete`, with module-level dedupe so two consumers do not double-POST. The global `<DesktopHandoffListener>` and the `/sign-in` page both consume the hook; the listener renders a toast everywhere except `/sign-in`, where the page renders a full-page card instead.

**Tech Stack:** Next.js 16 App Router (apps/web), React 19, Better Auth (`@/lib/auth-client`), Vitest + Testing Library + happy-dom.

**Spec:** `docs/superpowers/specs/2026-05-21-desktop-handoff-signin-page-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `apps/web/src/lib/use-desktop-handoff.ts` | Create | Hook + dedupe map + `clearHandoff(state)` retry helper + `__resetDesktopHandoffForTests()` |
| `apps/web/src/lib/use-desktop-handoff.test.ts` | Create | Unit tests for the hook |
| `apps/web/src/components/desktop-handoff-listener.tsx` | Modify | Consume hook, suppress on `/sign-in` |
| `apps/web/src/components/desktop-handoff-listener.test.tsx` | Create | Tests for pathname suppression + 3-state toast |
| `apps/web/src/app/sign-in/page.tsx` | Modify | Session-aware branching + `<DesktopReturnPanel>` |
| `apps/web/src/app/sign-in/page.test.tsx` | Create | Component tests for all four render states |

All work happens in `apps/web`. No worker, electron, or tauri changes.

**Commands** (run from `apps/web`):

- Run a single test file: `pnpm test src/lib/use-desktop-handoff.test.ts`
- Run all tests: `pnpm test`
- Type-check: `pnpm exec tsc --noEmit`

`pnpm test` is wired to `vitest run`. The path alias `@` maps to `./src`.

---

## Task 1: `useDesktopHandoff` hook — happy path (no params)

**Files:**
- Create: `apps/web/src/lib/use-desktop-handoff.test.ts`
- Create: `apps/web/src/lib/use-desktop-handoff.ts`

- [ ] **Step 1.1: Write the failing test**

```ts
// apps/web/src/lib/use-desktop-handoff.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook } from "@testing-library/react"

const mockUseSession = vi.fn()
const mockUseSearchParams = vi.fn()

vi.mock("@/lib/auth-client", () => ({
  useSession: () => mockUseSession(),
}))
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
}))

import {
  useDesktopHandoff,
  __resetDesktopHandoffForTests,
} from "./use-desktop-handoff"

function paramsFrom(obj: Record<string, string>): URLSearchParams {
  return new URLSearchParams(obj)
}

beforeEach(() => {
  __resetDesktopHandoffForTests()
  mockUseSession.mockReturnValue({ data: null, isPending: false })
  mockUseSearchParams.mockReturnValue(paramsFrom({}))
  vi.stubGlobal("fetch", vi.fn())
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe("useDesktopHandoff", () => {
  it("returns inactive when no desktop params are present", () => {
    const { result } = renderHook(() => useDesktopHandoff())
    expect(result.current).toEqual({
      isDesktopFlow: false,
      status: "inactive",
      errorMsg: "",
    })
  })
})
```

- [ ] **Step 1.2: Run test to verify it fails**

```bash
cd apps/web && pnpm test src/lib/use-desktop-handoff.test.ts
```

Expected: FAIL — `Cannot find module './use-desktop-handoff'`.

- [ ] **Step 1.3: Create minimal hook implementation**

```ts
// apps/web/src/lib/use-desktop-handoff.ts
"use client"

import { useEffect, useRef, useState } from "react"
import { useSearchParams } from "next/navigation"
import { useSession } from "@/lib/auth-client"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org"

export type HandoffStatus =
  | "inactive"
  | "waiting"
  | "completing"
  | "done"
  | "error"

export interface HandoffResult {
  isDesktopFlow: boolean
  status: HandoffStatus
  errorMsg: string
}

const inflight = new Map<string, Promise<void>>()

export function clearHandoff(state: string): void {
  inflight.delete(state)
}

export function __resetDesktopHandoffForTests(): void {
  inflight.clear()
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function useDesktopHandoff(): HandoffResult {
  const params = useSearchParams()
  const isHandoff = params?.get("login") === "true"
  const state = params?.get("state") ?? null
  const isDesktopFlow = isHandoff && !!state && UUID_RE.test(state)

  const session = useSession()
  const sessionData = session.data
  const isPending = session.isPending

  const [status, setStatus] = useState<HandoffStatus>("inactive")
  const [errorMsg, setErrorMsg] = useState("")

  useEffect(() => {
    if (!isDesktopFlow || !state) {
      setStatus("inactive")
      return
    }
    if (isPending) return
    if (!sessionData) {
      setStatus("waiting")
      return
    }

    setStatus("completing")

    let cancelled = false
    const existing = inflight.get(state)
    const promise =
      existing ??
      fetch(`${API_URL}/desktop/start/complete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ state }),
        credentials: "include",
      }).then(async (res) => {
        if (!res.ok) {
          const body = await res.text().catch(() => "")
          throw new Error(`handoff failed (${res.status}): ${body}`)
        }
      })

    if (!existing) inflight.set(state, promise)

    promise
      .then(() => {
        if (!cancelled) setStatus("done")
      })
      .catch((err: unknown) => {
        if (cancelled) return
        const msg = err instanceof Error ? err.message : "Unknown error"
        setErrorMsg(msg)
        setStatus("error")
      })

    return () => {
      cancelled = true
    }
  }, [isDesktopFlow, state, isPending, sessionData])

  return { isDesktopFlow, status, errorMsg }
}
```

- [ ] **Step 1.4: Run test to verify it passes**

```bash
cd apps/web && pnpm test src/lib/use-desktop-handoff.test.ts
```

Expected: PASS — 1 test.

- [ ] **Step 1.5: Commit**

```bash
git add apps/web/src/lib/use-desktop-handoff.ts apps/web/src/lib/use-desktop-handoff.test.ts
git commit -m "feat(web): add useDesktopHandoff hook skeleton"
```

---

## Task 2: `useDesktopHandoff` — waiting state

**Files:**
- Modify: `apps/web/src/lib/use-desktop-handoff.test.ts`

- [ ] **Step 2.1: Add the failing test**

Append inside the existing `describe("useDesktopHandoff", ...)` block:

```ts
  it("returns waiting when params are present but session has not arrived", () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "11111111-1111-4111-8111-111111111111",
      }),
    )
    mockUseSession.mockReturnValue({ data: null, isPending: false })

    const { result } = renderHook(() => useDesktopHandoff())

    expect(result.current.isDesktopFlow).toBe(true)
    expect(result.current.status).toBe("waiting")
    expect(globalThis.fetch).not.toHaveBeenCalled()
  })

  it("treats a malformed state param as not-a-desktop-flow", () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({ login: "true", state: "not-a-uuid" }),
    )
    mockUseSession.mockReturnValue({ data: null, isPending: false })

    const { result } = renderHook(() => useDesktopHandoff())

    expect(result.current.isDesktopFlow).toBe(false)
    expect(result.current.status).toBe("inactive")
  })
```

- [ ] **Step 2.2: Run tests to verify they pass**

```bash
cd apps/web && pnpm test src/lib/use-desktop-handoff.test.ts
```

Expected: PASS — 3 tests.

- [ ] **Step 2.3: Commit**

```bash
git add apps/web/src/lib/use-desktop-handoff.test.ts
git commit -m "test(web): cover useDesktopHandoff waiting + malformed state"
```

---

## Task 3: `useDesktopHandoff` — completing → done

**Files:**
- Modify: `apps/web/src/lib/use-desktop-handoff.test.ts`

- [ ] **Step 3.1: Write the failing test**

Append:

```ts
  it("POSTs to /desktop/start/complete and transitions to done", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "22222222-2222-4222-8222-222222222222",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )

    const { result } = renderHook(() => useDesktopHandoff())

    // First commit: completing
    expect(result.current.status).toBe("completing")
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toMatch(/\/desktop\/start\/complete$/)
    expect(init).toMatchObject({
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
    })
    expect(JSON.parse(init.body)).toEqual({
      state: "22222222-2222-4222-8222-222222222222",
    })

    await vi.waitFor(() => expect(result.current.status).toBe("done"))
    expect(result.current.errorMsg).toBe("")
  })
```

- [ ] **Step 3.2: Run test**

```bash
cd apps/web && pnpm test src/lib/use-desktop-handoff.test.ts -t "transitions to done"
```

Expected: PASS — the implementation from Task 1 already handles this. If it fails, debug before continuing.

- [ ] **Step 3.3: Commit**

```bash
git add apps/web/src/lib/use-desktop-handoff.test.ts
git commit -m "test(web): cover useDesktopHandoff completing→done path"
```

---

## Task 4: `useDesktopHandoff` — error path

**Files:**
- Modify: `apps/web/src/lib/use-desktop-handoff.test.ts`

- [ ] **Step 4.1: Write the failing test**

Append:

```ts
  it("transitions to error when POST returns non-2xx", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "33333333-3333-4333-8333-333333333333",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(
      new Response("nope", { status: 500 }),
    )

    const { result } = renderHook(() => useDesktopHandoff())

    await vi.waitFor(() => expect(result.current.status).toBe("error"))
    expect(result.current.errorMsg).toMatch(/handoff failed \(500\): nope/)
  })

  it("transitions to error when fetch throws", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "44444444-4444-4444-8444-444444444444",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockRejectedValue(new Error("boom"))

    const { result } = renderHook(() => useDesktopHandoff())

    await vi.waitFor(() => expect(result.current.status).toBe("error"))
    expect(result.current.errorMsg).toBe("boom")
  })
```

- [ ] **Step 4.2: Run tests**

```bash
cd apps/web && pnpm test src/lib/use-desktop-handoff.test.ts
```

Expected: PASS — 5 tests.

- [ ] **Step 4.3: Commit**

```bash
git add apps/web/src/lib/use-desktop-handoff.test.ts
git commit -m "test(web): cover useDesktopHandoff error paths"
```

---

## Task 5: `useDesktopHandoff` — dedupe across two consumers

**Files:**
- Modify: `apps/web/src/lib/use-desktop-handoff.test.ts`

- [ ] **Step 5.1: Write the failing test**

Append:

```ts
  it("POSTs exactly once when two consumers mount with the same state", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "55555555-5555-4555-8555-555555555555",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(new Response("{}", { status: 200 }))

    const a = renderHook(() => useDesktopHandoff())
    const b = renderHook(() => useDesktopHandoff())

    await vi.waitFor(() => {
      expect(a.result.current.status).toBe("done")
      expect(b.result.current.status).toBe("done")
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("re-POSTs after clearHandoff(state) is called", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "66666666-6666-4666-8666-666666666666",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(new Response("{}", { status: 200 }))

    const first = renderHook(() => useDesktopHandoff())
    await vi.waitFor(() => expect(first.result.current.status).toBe("done"))
    expect(fetchMock).toHaveBeenCalledTimes(1)

    const { clearHandoff } = await import("./use-desktop-handoff")
    clearHandoff("66666666-6666-4666-8666-666666666666")

    const second = renderHook(() => useDesktopHandoff())
    await vi.waitFor(() => expect(second.result.current.status).toBe("done"))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })
```

- [ ] **Step 5.2: Run tests**

```bash
cd apps/web && pnpm test src/lib/use-desktop-handoff.test.ts
```

Expected: PASS — 7 tests. (The implementation from Task 1 already dedupes via the module-level `inflight` Map.)

- [ ] **Step 5.3: Commit**

```bash
git add apps/web/src/lib/use-desktop-handoff.test.ts
git commit -m "test(web): cover useDesktopHandoff dedupe + clearHandoff retry"
```

---

## Task 6: Refactor `DesktopHandoffListener` — write the tests first

**Files:**
- Create: `apps/web/src/components/desktop-handoff-listener.test.tsx`

- [ ] **Step 6.1: Write the failing test**

```tsx
// apps/web/src/components/desktop-handoff-listener.test.tsx
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"

const mockUseSession = vi.fn()
const mockUseSearchParams = vi.fn()
const mockUsePathname = vi.fn()

vi.mock("@/lib/auth-client", () => ({
  useSession: () => mockUseSession(),
}))
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
  usePathname: () => mockUsePathname(),
}))

import { __resetDesktopHandoffForTests } from "@/lib/use-desktop-handoff"
import { DesktopHandoffListener } from "./desktop-handoff-listener"

function paramsFrom(obj: Record<string, string>): URLSearchParams {
  return new URLSearchParams(obj)
}

beforeEach(() => {
  __resetDesktopHandoffForTests()
  vi.stubGlobal(
    "fetch",
    vi.fn(() => Promise.resolve(new Response("{}", { status: 200 }))),
  )
  mockUseSession.mockReturnValue({ data: null, isPending: false })
  mockUseSearchParams.mockReturnValue(paramsFrom({}))
  mockUsePathname.mockReturnValue("/")
})

describe("<DesktopHandoffListener>", () => {
  it("renders nothing on /sign-in even when desktop params are present", () => {
    mockUsePathname.mockReturnValue("/sign-in")
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "77777777-7777-4777-8777-777777777777",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })

    const { container } = render(<DesktopHandoffListener />)
    expect(container.firstChild).toBeNull()
  })

  it("renders nothing on / when no desktop params are present", () => {
    const { container } = render(<DesktopHandoffListener />)
    expect(container.firstChild).toBeNull()
  })

  it("renders the toast on / when handoff is done", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "88888888-8888-4888-8888-888888888888",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })

    render(<DesktopHandoffListener />)

    expect(await screen.findByText(/signed in/i)).toBeInTheDocument()
    expect(
      screen.getByText(/return to the rishi app to continue/i),
    ).toBeInTheDocument()
  })
})
```

- [ ] **Step 6.2: Run test to verify it fails**

```bash
cd apps/web && pnpm test src/components/desktop-handoff-listener.test.tsx
```

Expected: FAIL — the current `DesktopHandoffListener` does not call `usePathname()` and does not return `null` on `/sign-in`, so the first test will fail.

- [ ] **Step 6.3: Replace `desktop-handoff-listener.tsx` with the refactored version**

Overwrite the entire file:

```tsx
"use client"

import { usePathname } from "next/navigation"
import { useDesktopHandoff } from "@/lib/use-desktop-handoff"

/**
 * When the desktop app sends a user to app.fidexa.org/?login=true&state=...,
 * we wait for them to be signed in (via magic-link or social), then ask the
 * worker to write the session into Redis under the state key. The desktop is
 * polling /desktop/poll and will pick it up on its next tick.
 *
 * On /sign-in, the page renders its own full-page handoff card, so the toast
 * is suppressed to avoid duplicated UI.
 */
export function DesktopHandoffListener() {
  const pathname = usePathname()
  const { isDesktopFlow, status, errorMsg } = useDesktopHandoff()

  if (pathname === "/sign-in") return null
  if (!isDesktopFlow) return null
  if (status === "inactive" || status === "waiting") return null

  return (
    <div className="fixed bottom-4 right-4 z-50 max-w-sm rounded-lg border bg-background p-4 shadow-lg">
      {status === "completing" && (
        <p className="text-sm text-muted-foreground">Signing you into Rishi…</p>
      )}
      {status === "done" && (
        <>
          <p className="text-sm font-medium">Signed in</p>
          <p className="text-xs text-muted-foreground mt-1">
            Return to the Rishi app to continue. You can close this tab.
          </p>
        </>
      )}
      {status === "error" && (
        <>
          <p className="text-sm font-medium text-destructive">Sign-in handoff failed</p>
          <p className="text-xs text-muted-foreground mt-1 break-words">{errorMsg}</p>
        </>
      )}
    </div>
  )
}
```

- [ ] **Step 6.4: Run tests to verify pass**

```bash
cd apps/web && pnpm test src/components/desktop-handoff-listener.test.tsx
```

Expected: PASS — 3 tests.

- [ ] **Step 6.5: Run the whole web test suite to confirm nothing else broke**

```bash
cd apps/web && pnpm test
```

Expected: PASS.

- [ ] **Step 6.6: Commit**

```bash
git add apps/web/src/components/desktop-handoff-listener.tsx apps/web/src/components/desktop-handoff-listener.test.tsx
git commit -m "refactor(web): listener consumes useDesktopHandoff, suppresses on /sign-in"
```

---

## Task 7: `/sign-in` page — write the tests first

**Files:**
- Create: `apps/web/src/app/sign-in/page.test.tsx`

- [ ] **Step 7.1: Write the failing test**

```tsx
// apps/web/src/app/sign-in/page.test.tsx
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"

const mockUseSession = vi.fn()
const mockUseSearchParams = vi.fn()
const mockReplace = vi.fn()
const mockUsePathname = vi.fn(() => "/sign-in")
const mockSocial = vi.fn()
const mockMagicLink = vi.fn()
const mockPasskey = vi.fn()

vi.mock("@/lib/auth-client", () => ({
  useSession: () => mockUseSession(),
  signIn: { social: (...args: unknown[]) => mockSocial(...args) },
  authClient: {
    signIn: {
      magicLink: (...args: unknown[]) => mockMagicLink(...args),
      passkey: (...args: unknown[]) => mockPasskey(...args),
    },
  },
}))
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
  usePathname: () => mockUsePathname(),
  useRouter: () => ({ replace: mockReplace, push: vi.fn() }),
}))

import { __resetDesktopHandoffForTests } from "@/lib/use-desktop-handoff"
import SignInPage from "./page"

function paramsFrom(obj: Record<string, string>): URLSearchParams {
  return new URLSearchParams(obj)
}

beforeEach(() => {
  __resetDesktopHandoffForTests()
  mockReplace.mockReset()
  mockSocial.mockReset()
  mockMagicLink.mockReset()
  mockPasskey.mockReset()
  mockUseSession.mockReturnValue({ data: null, isPending: false })
  mockUseSearchParams.mockReturnValue(paramsFrom({}))
  vi.stubGlobal(
    "fetch",
    vi.fn(() => Promise.resolve(new Response("{}", { status: 200 }))),
  )
})

describe("<SignInPage>", () => {
  it("renders the form when the user is not signed in", () => {
    render(<SignInPage />)
    expect(
      screen.getByRole("heading", { name: /sign in to rishi/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByPlaceholderText(/you@example.com/i),
    ).toBeInTheDocument()
  })
})
```

- [ ] **Step 7.2: Run test to verify it passes (or fails gracefully)**

```bash
cd apps/web && pnpm test src/app/sign-in/page.test.tsx
```

Expected: PASS — the first test exercises the current behavior. If it fails, the mock wiring is wrong and must be fixed before continuing.

- [ ] **Step 7.3: Add the failing "skeleton while pending" test**

Append inside the `describe` block:

```tsx
  it("renders a skeleton (no form) while session is pending", () => {
    mockUseSession.mockReturnValue({ data: null, isPending: true })
    render(<SignInPage />)
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByPlaceholderText(/you@example.com/i),
    ).not.toBeInTheDocument()
  })
```

- [ ] **Step 7.4: Run test to verify it fails**

```bash
cd apps/web && pnpm test src/app/sign-in/page.test.tsx -t "skeleton"
```

Expected: FAIL — current page ignores `isPending` and always renders the form.

- [ ] **Step 7.5: Add the failing "redirect when signed in without desktop params" test**

Append:

```tsx
  it("redirects to returnTo when signed in and no desktop params", () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(paramsFrom({ returnTo: "/library" }))

    render(<SignInPage />)

    expect(mockReplace).toHaveBeenCalledWith("/library")
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
  })

  it("redirects to / when signed in with no returnTo", () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    render(<SignInPage />)
    expect(mockReplace).toHaveBeenCalledWith("/")
  })
```

- [ ] **Step 7.6: Add the failing "desktop return panel" tests**

Append:

```tsx
  it("renders 'Completing sign-in' while handoff is in flight", () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "99999999-9999-4999-8999-999999999999",
      }),
    )
    // Hang fetch forever so we observe the completing state
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})))

    render(<SignInPage />)

    expect(screen.getByText(/completing sign-in/i)).toBeInTheDocument()
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
    expect(mockReplace).not.toHaveBeenCalled()
  })

  it("renders 'Return to the Rishi app' when handoff is done", async () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      }),
    )

    render(<SignInPage />)

    expect(
      await screen.findByRole("heading", { name: /you're signed in/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/return to the rishi app to continue/i),
    ).toBeInTheDocument()
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
  })

  it("renders the error panel with retry when handoff fails", async () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      }),
    )
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response("nope", { status: 500 }))),
    )

    render(<SignInPage />)

    expect(
      await screen.findByRole("heading", { name: /sign-in handoff failed/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: /try again/i }),
    ).toBeInTheDocument()
  })
```

- [ ] **Step 7.7: Run tests to verify they fail**

```bash
cd apps/web && pnpm test src/app/sign-in/page.test.tsx
```

Expected: FAIL — the new tests fail; only the "renders the form" test from Step 7.1 should pass.

- [ ] **Step 7.8: Commit the failing tests**

```bash
git add apps/web/src/app/sign-in/page.test.tsx
git commit -m "test(web): red — sign-in page session-aware branching"
```

---

## Task 8: `/sign-in` page — implement session-aware branching

**Files:**
- Modify: `apps/web/src/app/sign-in/page.tsx`

- [ ] **Step 8.1: Replace the entire file**

```tsx
"use client"

import { useState, useEffect, Suspense, type FormEvent } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import {
  authClient,
  signIn,
  useSession,
} from "@/lib/auth-client"
import {
  clearHandoff,
  useDesktopHandoff,
  type HandoffStatus,
} from "@/lib/use-desktop-handoff"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

function SignInSkeleton() {
  return <div className="max-w-md mx-auto py-20" data-testid="sign-in-skeleton" />
}

function DesktopReturnPanel({
  status,
  errorMsg,
  state,
  onRetry,
}: {
  status: HandoffStatus
  errorMsg: string
  state: string | null
  onRetry: () => void
}) {
  return (
    <div className="max-w-md mx-auto py-20 text-center">
      {status === "completing" && (
        <>
          <h1 className="text-2xl font-bold mb-2">Completing sign-in…</h1>
          <p className="text-muted-foreground">
            Hang tight — finishing the handshake with the Rishi app.
          </p>
        </>
      )}
      {status === "done" && (
        <>
          <h1 className="text-2xl font-bold mb-2">You&apos;re signed in</h1>
          <p className="text-muted-foreground">
            Return to the Rishi app to continue. You can close this tab.
          </p>
        </>
      )}
      {status === "error" && (
        <>
          <h1 className="text-2xl font-bold mb-2 text-destructive">
            Sign-in handoff failed
          </h1>
          <p className="text-muted-foreground mb-6 break-words">{errorMsg}</p>
          <Button
            onClick={() => {
              if (state) clearHandoff(state)
              onRetry()
            }}
          >
            Try again
          </Button>
        </>
      )}
    </div>
  )
}

function SignInForm({
  params,
  returnTo,
}: {
  params: URLSearchParams
  returnTo: string
}) {
  const [email, setEmail] = useState("")
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">("idle")
  const [errorMsg, setErrorMsg] = useState<string>("")

  async function sendMagicLink(e: FormEvent) {
    e.preventDefault()
    setStatus("sending")
    setErrorMsg("")
    try {
      const callbackURL =
        typeof window !== "undefined"
          ? window.location.origin +
            (params.toString() ? "/?" + params.toString() : returnTo)
          : returnTo
      await authClient.signIn.magicLink({ email, callbackURL })
      setStatus("sent")
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Failed to send link"
      setErrorMsg(message)
      setStatus("error")
    }
  }

  if (status === "sent") {
    return (
      <div className="max-w-md mx-auto py-20 text-center">
        <h1 className="text-2xl font-bold mb-4">Check your email</h1>
        <p className="text-muted-foreground mb-6">
          We sent a sign-in link to <span className="font-medium">{email}</span>.
          Open it on this device to continue.
        </p>
        <Button variant="ghost" onClick={() => setStatus("idle")}>
          Use a different email
        </Button>
      </div>
    )
  }

  return (
    <div className="max-w-md mx-auto py-20">
      <h1 className="text-2xl font-bold mb-2">Sign in to Rishi</h1>
      <p className="text-muted-foreground mb-6">
        We&apos;ll email you a link to sign in instantly.
      </p>
      <form onSubmit={sendMagicLink} className="space-y-3">
        <Input
          type="email"
          required
          autoFocus
          placeholder="you@example.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          disabled={status === "sending"}
        />
        <Button type="submit" className="w-full" disabled={status === "sending"}>
          {status === "sending" ? "Sending…" : "Continue"}
        </Button>
        {errorMsg && <p className="text-sm text-destructive">{errorMsg}</p>}
      </form>
      <div className="my-6 flex items-center gap-2">
        <div className="flex-1 h-px bg-border" />
        <span className="text-xs text-muted-foreground">OR</span>
        <div className="flex-1 h-px bg-border" />
      </div>
      <Button
        variant="outline"
        className="w-full"
        onClick={() =>
          signIn.social({
            provider: "google",
            callbackURL: typeof window !== "undefined" ? window.location.href : "/",
          })
        }
      >
        Continue with Google
      </Button>
      <Button
        variant="outline"
        className="w-full mt-2"
        onClick={async () => {
          try {
            await authClient.signIn.passkey({ autoFill: false })
          } catch (err: unknown) {
            const message = err instanceof Error ? err.message : "Passkey sign-in failed"
            setErrorMsg(message)
          }
        }}
      >
        Sign in with passkey
      </Button>
    </div>
  )
}

function SignInPageInner() {
  const router = useRouter()
  const params = useSearchParams()
  const provider = params.get("provider")
  const returnTo = params.get("returnTo") ?? "/"
  const state = params.get("state")
  const { data: session, isPending } = useSession()
  const handoff = useDesktopHandoff()
  const [retryNonce, setRetryNonce] = useState(0)

  // Auto-kick Google OAuth on ?provider=google (unchanged)
  useEffect(() => {
    if (provider !== "google") return
    void signIn.social({
      provider: "google",
      callbackURL:
        typeof window !== "undefined"
          ? window.location.href.replace("provider=google", "")
          : "/",
    })
  }, [provider])

  // Web flow: signed in but not a desktop handoff → bounce home
  useEffect(() => {
    if (isPending) return
    if (!session) return
    if (handoff.isDesktopFlow) return
    router.replace(returnTo)
  }, [isPending, session, handoff.isDesktopFlow, returnTo, router])

  if (isPending) return <SignInSkeleton />

  if (session && handoff.isDesktopFlow) {
    return (
      <DesktopReturnPanel
        status={handoff.status}
        errorMsg={handoff.errorMsg}
        state={state}
        onRetry={() => setRetryNonce((n) => n + 1)}
        key={retryNonce}
      />
    )
  }

  if (session) return <SignInSkeleton />

  return <SignInForm params={params} returnTo={returnTo} />
}

export default function SignInPage() {
  return (
    <Suspense fallback={<SignInSkeleton />}>
      <SignInPageInner />
    </Suspense>
  )
}
```

- [ ] **Step 8.2: Run sign-in tests**

```bash
cd apps/web && pnpm test src/app/sign-in/page.test.tsx
```

Expected: PASS — 7 tests.

- [ ] **Step 8.3: Run the whole web suite**

```bash
cd apps/web && pnpm test
```

Expected: PASS.

- [ ] **Step 8.4: Type-check**

```bash
cd apps/web && pnpm exec tsc --noEmit
```

Expected: no errors in `src/app/sign-in/page.tsx`, `src/components/desktop-handoff-listener.tsx`, or `src/lib/use-desktop-handoff.ts`. Pre-existing errors elsewhere in the monorepo are out of scope.

- [ ] **Step 8.5: Commit**

```bash
git add apps/web/src/app/sign-in/page.tsx
git commit -m "feat(web): sign-in page is session-aware, renders desktop return panel"
```

---

## Task 9: Manual smoke test in the browser

**No file changes — verification only.**

- [ ] **Step 9.1: Start the web dev server and worker**

In one terminal:

```bash
cd apps/web && pnpm dev
```

In another:

```bash
cd workers/worker && pnpm dev
```

(Skip the worker step if `NEXT_PUBLIC_API_URL` already points at a deployed environment.)

- [ ] **Step 9.2: Reproduce the original bug path**

1. Open the desktop app (rishi-electron or rishi-tauri).
2. Click "Continue with Google".
3. Complete Google sign-in in the browser.

Expected: the browser tab now shows a centered "You're signed in / Return to the Rishi app to continue." panel — **no sign-in form, no bottom-right toast**. The desktop app picks up the session within ~2 seconds.

- [ ] **Step 9.3: Verify the magic-link flow still works**

1. From the desktop app, request a magic link.
2. Open the email link in the browser.

Expected: lands on `/?login=true&state=...` (the homepage). The bottom-right "Signed in" toast appears (since pathname is `/`, not `/sign-in`).

- [ ] **Step 9.4: Verify the plain-web redirect**

1. While signed in, visit `https://app.fidexa.org/sign-in` directly.

Expected: instantly redirects to `/` (or `/library` if `?returnTo=/library`).

- [ ] **Step 9.5: Verify the error path (manual)**

This step is optional and only worth doing if the worker can be made to return 500.

1. Stop the worker mid-flow, or intercept the request and return 500.
2. Repeat the desktop sign-in flow.

Expected: the page shows "Sign-in handoff failed" with the error message and a "Try again" button. Clicking "Try again" re-fires the POST.

- [ ] **Step 9.6: Commit the spec/plan if anything in this plan was tweaked along the way**

If steps had to be amended, amend them in this plan file and commit. Otherwise, skip.

---

## Done criteria

- All `apps/web` tests pass (`pnpm test` from `apps/web`).
- Type-check is clean for the three changed source files.
- Manual smoke test in Task 9 confirms the Google OAuth flow no longer shows the sign-in form after handoff.
- Three commits land on `main` (or the feature branch): one for the hook, one for the listener refactor, one for the sign-in page rewrite. Test-only commits in between are fine — small commits are encouraged.
