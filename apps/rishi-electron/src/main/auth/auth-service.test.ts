import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

// auth-service.ts imports `electron` (shell, BrowserWindow). Stub it so the
// module loads under vitest. Mirrors `queries.test.ts`.
vi.mock('electron', () => ({
  shell: { openExternal: vi.fn().mockResolvedValue(undefined) },
  BrowserWindow: { getAllWindows: () => [] },
  ipcMain: { handle: () => {} },
  app: { on: () => {}, getPath: () => '/tmp' }
}))

// We stub the session-store so we can observe writes vs clears in tests
// without touching the filesystem or safeStorage.
const sessionStoreMock = vi.hoisted(() => ({
  readSession: vi.fn<() => Promise<string | null>>().mockResolvedValue(null),
  writeSession: vi.fn<(token: string) => Promise<void>>().mockResolvedValue(undefined),
  clearSession: vi.fn<() => Promise<void>>().mockResolvedValue(undefined)
}))

vi.mock('./session-store', () => sessionStoreMock)

type FetchArgs = [input: RequestInfo | URL, init?: RequestInit]
type FetchImpl = (...args: FetchArgs) => Promise<Response>

const originalFetch = global.fetch

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}

describe('AuthService — signOut cancels in-flight polls atomically', () => {
  beforeEach(() => {
    vi.resetModules()
    sessionStoreMock.readSession.mockReset().mockResolvedValue(null)
    sessionStoreMock.writeSession.mockReset().mockResolvedValue(undefined)
    sessionStoreMock.clearSession.mockReset().mockResolvedValue(undefined)
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('does not write a token to the session store when signOut runs while a poll is in-flight', async () => {
    // Resolver lets the test hold the /desktop/poll response open until after signOut.
    let resolvePoll: (res: Response) => void = () => {}
    const pollResponsePromise = new Promise<Response>((r) => {
      resolvePoll = r
    })

    const fetchImpl: FetchImpl = vi.fn(async (input) => {
      const url = typeof input === 'string' ? input : input.toString()
      if (url.endsWith('/desktop/start')) {
        return jsonResponse(200, { state: 'state-1' })
      }
      if (url.endsWith('/desktop/poll')) {
        // Slow response — won't resolve until the test releases it.
        return pollResponsePromise
      }
      if (url.endsWith('/desktop/cancel')) {
        return new Response('', { status: 200 })
      }
      if (url.endsWith('/api/auth/sign-out')) {
        return new Response('', { status: 200 })
      }
      if (url.endsWith('/api/auth/get-session')) {
        return jsonResponse(200, { user: { id: 'u1', email: 'a@b.c' } })
      }
      throw new Error(`unexpected fetch: ${url}`)
    })
    global.fetch = fetchImpl as unknown as typeof fetch

    const { authService } = await import('./auth-service')

    // Kick off the magic-link flow → spawns the polling loop in the background.
    await authService.startMagicLink('a@b.c')

    // signOut while poll is still pending — should abort the in-flight poll
    // BEFORE clearSession so no late write races in.
    await authService.signOut()

    // Now let the slow /desktop/poll respond with a 200 + token. This response
    // was already in-flight when signOut ran — the fix is that the poll
    // callback short-circuits and never writes.
    resolvePoll(jsonResponse(200, { session_token: 'late-arriving-token' }))

    // Give the microtask queue a couple of ticks to run the post-await branch.
    await new Promise((r) => setTimeout(r, 10))

    expect(sessionStoreMock.writeSession).not.toHaveBeenCalled()
    expect(sessionStoreMock.clearSession).toHaveBeenCalledTimes(1)
  })

  it('exposes the in-flight poll AbortSignal as aborted after signOut', async () => {
    const signals: AbortSignal[] = []
    let resolvePoll: (res: Response) => void = () => {}
    const pollResponsePromise = new Promise<Response>((r) => {
      resolvePoll = r
    })

    const fetchImpl: FetchImpl = vi.fn(async (input, init) => {
      const url = typeof input === 'string' ? input : input.toString()
      if (url.endsWith('/desktop/start')) {
        return jsonResponse(200, { state: 'state-2' })
      }
      if (url.endsWith('/desktop/poll')) {
        if (init?.signal) signals.push(init.signal)
        return pollResponsePromise
      }
      if (url.endsWith('/desktop/cancel')) return new Response('', { status: 200 })
      if (url.endsWith('/api/auth/sign-out')) return new Response('', { status: 200 })
      throw new Error(`unexpected fetch: ${url}`)
    })
    global.fetch = fetchImpl as unknown as typeof fetch

    const { authService } = await import('./auth-service')

    await authService.startMagicLink('b@b.c')
    // Yield once so the polling loop actually issues its first fetch and we
    // capture the signal.
    await new Promise((r) => setTimeout(r, 0))

    await authService.signOut()

    expect(signals.length).toBeGreaterThan(0)
    expect(signals.every((s) => s.aborted)).toBe(true)

    // Resolve the held poll so the in-flight loop unwinds cleanly.
    resolvePoll(jsonResponse(200, { session_token: 'never-applied' }))
    await new Promise((r) => setTimeout(r, 10))
  })

  it('calling signOut twice does not throw and remains idempotent', async () => {
    const fetchImpl: FetchImpl = vi.fn(async (input) => {
      const url = typeof input === 'string' ? input : input.toString()
      if (url.endsWith('/api/auth/sign-out')) return new Response('', { status: 200 })
      if (url.endsWith('/desktop/cancel')) return new Response('', { status: 200 })
      throw new Error(`unexpected fetch: ${url}`)
    })
    global.fetch = fetchImpl as unknown as typeof fetch

    const { authService } = await import('./auth-service')

    await expect(authService.signOut()).resolves.not.toThrow()
    await expect(authService.signOut()).resolves.not.toThrow()
    // clearSession runs each time but writeSession never does
    expect(sessionStoreMock.writeSession).not.toHaveBeenCalled()
  })
})
