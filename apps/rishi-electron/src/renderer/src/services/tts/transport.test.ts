import { describe, it, expect, vi } from 'vitest'
import { fetchAudio, TtsTransportError } from './transport'
import type { AuthHeader, TtsConfig } from './types'

function makeFetch(opts: {
  audioBytes?: Uint8Array
  status?: number
  errorBody?: string
  retryAfter?: string
  rejectWith?: Error
}) {
  const status = opts.status ?? 200
  const bytes = opts.audioBytes ?? new Uint8Array([0xff, 0xfb, 0x90])
  const calls: Array<{ url: string; init: RequestInit }> = []
  const fetch = vi.fn(async (url: string, init: RequestInit) => {
    calls.push({ url, init })
    if (opts.rejectWith) throw opts.rejectWith
    const headers = new Headers()
    if (opts.retryAfter) headers.set('Retry-After', opts.retryAfter)
    return new Response(status === 200 ? bytes : opts.errorBody ?? '', {
      status,
      headers
    })
  })
  return { fetch, calls }
}

const baseConfig: TtsConfig = {
  audioWorkerUrl: 'https://api.example.com/audio/speech',
  cacheMaxBytes: 500 * 1024 * 1024,
  maxConcurrent: 8
}

const bearer: AuthHeader = { kind: 'bearer', token: 'tok-123' }
const devBypass: AuthHeader = { kind: 'dev-bypass', secret: 's3cret' }

describe('fetchAudio (transport)', () => {
  it('POSTs JSON body with Authorization: Bearer header and returns bytes', async () => {
    const { fetch, calls } = makeFetch({ audioBytes: new Uint8Array([1, 2, 3, 4]) })

    const bytes = await fetchAudio({
      fetch,
      auth: bearer,
      config: baseConfig,
      text: 'hello world'
    })

    expect(new Uint8Array(bytes)).toEqual(new Uint8Array([1, 2, 3, 4]))
    expect(calls).toHaveLength(1)
    expect(calls[0].url).toBe('https://api.example.com/audio/speech')
    expect(calls[0].init.method).toBe('POST')
    const headers = calls[0].init.headers as Record<string, string>
    expect(headers['Authorization']).toBe('Bearer tok-123')
    expect(headers['Content-Type']).toBe('application/json')
    expect(headers['X-Dev-Bypass']).toBeUndefined()
    const body = JSON.parse(calls[0].init.body as string)
    expect(body).toEqual({
      voice: 'alloy',
      input: 'hello world',
      response_format: 'mp3',
      speed: 1.0
    })
  })

  it('uses X-Dev-Bypass header (and no Authorization) when auth is dev-bypass', async () => {
    const { fetch, calls } = makeFetch({})

    await fetchAudio({ fetch, auth: devBypass, config: baseConfig, text: 'hi' })

    const headers = calls[0].init.headers as Record<string, string>
    expect(headers['X-Dev-Bypass']).toBe('s3cret')
    expect(headers['Authorization']).toBeUndefined()
  })

  it('throws TtsTransportError with retryable=false on 401', async () => {
    const { fetch } = makeFetch({ status: 401, errorBody: 'unauthorized' })

    const err = await fetchAudio({
      fetch,
      auth: bearer,
      config: baseConfig,
      text: 'hi'
    }).catch((e) => e)
    expect(err).toBeInstanceOf(TtsTransportError)
    expect(err.status).toBe(401)
    expect(err.retryable).toBe(false)
    expect(err.retryAfterMs).toBeNull()
  })

  it('throws TtsTransportError with retryable=true and parsed retryAfterMs on 429', async () => {
    const { fetch } = makeFetch({ status: 429, errorBody: 'slow down', retryAfter: '2' })

    const err = await fetchAudio({
      fetch,
      auth: bearer,
      config: baseConfig,
      text: 'hi'
    }).catch((e) => e)
    expect(err).toBeInstanceOf(TtsTransportError)
    expect(err.status).toBe(429)
    expect(err.retryable).toBe(true)
    expect(err.retryAfterMs).toBe(2000)
  })

  it('throws TtsTransportError with retryable=true on 503', async () => {
    const { fetch } = makeFetch({ status: 503, errorBody: 'down' })

    const err = await fetchAudio({
      fetch,
      auth: bearer,
      config: baseConfig,
      text: 'hi'
    }).catch((e) => e)
    expect(err).toBeInstanceOf(TtsTransportError)
    expect(err.status).toBe(503)
    expect(err.retryable).toBe(true)
  })

  it('propagates network errors raised by fetch', async () => {
    const { fetch } = makeFetch({ rejectWith: new Error('ECONNRESET') })

    await expect(
      fetchAudio({ fetch, auth: bearer, config: baseConfig, text: 'hi' })
    ).rejects.toThrow('ECONNRESET')
  })
})
