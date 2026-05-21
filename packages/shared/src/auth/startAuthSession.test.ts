import { describe, it, expect, vi } from 'vitest'
import { startAuthSession, completeAuthSession } from './startAuthSession'

describe('startAuthSession', () => {
  it('POSTs { code_challenge, provider } to /mobile/start and returns { authUrl, state, verifier }', async () => {
    const fetchMock = vi.fn(
      async (_url: string, _init?: RequestInit) =>
        new Response(
          JSON.stringify({
            state: 'srv-state-123',
            authUrl: 'https://example.com/sign-in?state=srv-state-123',
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        ),
    )

    const result = await startAuthSession({
      apiUrl: 'https://api.example.com',
      provider: 'google',
      fetch: fetchMock as unknown as typeof fetch,
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('https://api.example.com/mobile/start')
    expect(init?.method).toBe('POST')
    expect(init?.headers).toMatchObject({ 'Content-Type': 'application/json' })
    const body = JSON.parse(init?.body as string)
    expect(body).toHaveProperty('code_challenge')
    expect(body.provider).toBe('google')
    expect(body.code_challenge.length).toBeGreaterThanOrEqual(43)

    expect(result.authUrl).toBe('https://example.com/sign-in?state=srv-state-123')
    expect(result.state).toBe('srv-state-123')
    expect(result.verifier.length).toBeGreaterThanOrEqual(43)
  })

  it('defaults provider to google when not specified', async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ state: 's', authUrl: 'https://x/' }), { status: 200 }),
    )
    await startAuthSession({
      apiUrl: 'https://api.example.com',
      fetch: fetchMock as unknown as typeof fetch,
    })
    const body = JSON.parse(fetchMock.mock.calls[0][1]?.body as string)
    expect(body.provider).toBe('google')
  })

  it('throws when /mobile/start returns non-2xx', async () => {
    const fetchMock = vi.fn(
      async () => new Response(JSON.stringify({ error: 'bad_request' }), { status: 400 }),
    )
    await expect(
      startAuthSession({
        apiUrl: 'https://api.example.com',
        fetch: fetchMock as unknown as typeof fetch,
      }),
    ).rejects.toThrow(/mobile.*start.*400/i)
  })
})

describe('completeAuthSession', () => {
  it('POSTs { state, code_verifier } to /mobile/start/verify and returns the session token', async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          JSON.stringify({ session_token: 'sess-abc', user_id: 'user-1' }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        ),
    )

    const out = await completeAuthSession({
      apiUrl: 'https://api.example.com',
      state: 'srv-state-123',
      verifier: 'my-verifier-of-the-correct-length-1234567890ABC',
      fetch: fetchMock as unknown as typeof fetch,
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('https://api.example.com/mobile/start/verify')
    expect(init?.method).toBe('POST')
    const body = JSON.parse(init?.body as string)
    expect(body).toEqual({
      state: 'srv-state-123',
      code_verifier: 'my-verifier-of-the-correct-length-1234567890ABC',
    })
    expect(out).toEqual({ session_token: 'sess-abc', user_id: 'user-1' })
  })

  it('throws on 403 pkce_mismatch', async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ error: 'pkce_mismatch' }), { status: 403 }),
    )
    await expect(
      completeAuthSession({
        apiUrl: 'https://api.example.com',
        state: 's',
        verifier: 'v',
        fetch: fetchMock as unknown as typeof fetch,
      }),
    ).rejects.toThrow(/pkce|403/i)
  })

  it('throws on 410 expired', async () => {
    const fetchMock = vi.fn(
      async () => new Response(JSON.stringify({ error: 'expired' }), { status: 410 }),
    )
    await expect(
      completeAuthSession({
        apiUrl: 'https://api.example.com',
        state: 's',
        verifier: 'v',
        fetch: fetchMock as unknown as typeof fetch,
      }),
    ).rejects.toThrow(/expired|410/i)
  })
})
