import { describe, it, expect, vi } from 'vitest'
import { createVoiceChatService } from './service'
import type { ApiFetch } from '@rishi/shared/billing/realtime-usage-client'
import {
  makeSession,
  makeMedia,
  makeIpc,
  makeAgent,
  makeWebrtc,
  makeConfig,
  makeDeps
} from './service.test'

function jsonResponse(status: number, body: unknown = { ok: true }): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}

function responseDoneEvent(overrides?: {
  audioInputTokens?: number
  audioOutputTokens?: number
  textInputTokens?: number
  textOutputTokens?: number
}): { type: 'response.done'; response: { usage: Record<string, unknown> } } {
  const ai = overrides?.audioInputTokens ?? 0
  const ao = overrides?.audioOutputTokens ?? 0
  const ti = overrides?.textInputTokens ?? 0
  const to = overrides?.textOutputTokens ?? 0
  return {
    type: 'response.done',
    response: {
      usage: {
        input_tokens: ai + ti,
        input_token_details: { audio_tokens: ai, text_tokens: ti },
        output_tokens: ao + to,
        output_token_details: { audio_tokens: ao, text_tokens: to }
      }
    }
  }
}

describe('voice-chat billing wiring — accumulation', () => {
  it('accumulates usage across multiple response.done events in one session', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })

    session.fire(
      'transport_event',
      responseDoneEvent({ audioInputTokens: 100, audioOutputTokens: 50 })
    )
    session.fire(
      'transport_event',
      responseDoneEvent({ audioInputTokens: 200, textOutputTokens: 25 })
    )

    svc.deactivate()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).toHaveBeenCalledTimes(1)
    const [path, init] = apiFetch.mock.calls[0]!
    expect(path).toBe('/api/billing/realtime-usage')
    expect(JSON.parse(String(init?.body))).toEqual({
      audioInputTokens: 300,
      audioOutputTokens: 50,
      textInputTokens: 0,
      textOutputTokens: 25
    })
  })

  it('does NOT POST when no response.done events were observed', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })
    svc.deactivate()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).not.toHaveBeenCalled()
  })

  it('does NOT POST when usage exists but every counter is zero', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })
    session.fire('transport_event', responseDoneEvent({}))
    svc.deactivate()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).not.toHaveBeenCalled()
  })
})

describe('voice-chat billing wiring — failure isolation', () => {
  it('apiFetch rejection does not throw out of deactivate', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => {
      throw new Error('network down')
    })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })
    session.fire('transport_event', responseDoneEvent({ audioInputTokens: 10 }))

    expect(() => svc.deactivate()).not.toThrow()
    await new Promise((r) => setTimeout(r, 0))
    expect(svc.getState()).toBe('idle')
  })

  it('apiFetch non-2xx does not throw out of deactivate', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(500, { error: 'boom' }))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })
    session.fire('transport_event', responseDoneEvent({ audioInputTokens: 10 }))

    expect(() => svc.deactivate()).not.toThrow()
    await new Promise((r) => setTimeout(r, 0))
    expect(svc.getState()).toBe('idle')
  })

  it('a malformed response.done event does not crash the session', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })

    // No usage field.
    session.fire('transport_event', { type: 'response.done', response: {} })
    // Usage is null.
    session.fire('transport_event', { type: 'response.done', response: { usage: null } })
    // Followed by a valid event — accumulation must still work.
    session.fire('transport_event', responseDoneEvent({ audioInputTokens: 5 }))

    svc.deactivate()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(String(apiFetch.mock.calls[0]![1]?.body))).toMatchObject({
      audioInputTokens: 5
    })
  })

  it('non-response.done transport events are ignored', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })

    session.fire('transport_event', { type: 'response.created', response: {} })
    session.fire('transport_event', { type: 'session.updated' })

    svc.deactivate()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).not.toHaveBeenCalled()
  })
})

describe('voice-chat billing wiring — session isolation', () => {
  it('starting a new session resets the accumulator', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })
    session.fire('transport_event', responseDoneEvent({ audioInputTokens: 100 }))
    svc.deactivate()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(String(apiFetch.mock.calls[0]![1]?.body))).toMatchObject({
      audioInputTokens: 100
    })

    await svc.activate(2, { pageText: 'q' })
    session.fire('transport_event', responseDoneEvent({ audioInputTokens: 7 }))
    svc.deactivate()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).toHaveBeenCalledTimes(2)
    expect(JSON.parse(String(apiFetch.mock.calls[1]![1]?.body))).toMatchObject({
      audioInputTokens: 7
    })
  })

  it('reports on dispose() path as well as deactivate()', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })
    session.fire('transport_event', responseDoneEvent({ textOutputTokens: 42 }))

    svc.dispose()
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(String(apiFetch.mock.calls[0]![1]?.body))).toMatchObject({
      textOutputTokens: 42
    })
  })

  it('reports on session error teardown', async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200))
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, billing: { apiFetch } })
    )

    await svc.activate(1, { pageText: 'p' })
    session.fire('transport_event', responseDoneEvent({ audioOutputTokens: 9 }))

    // Trigger the session 'error' handler installed by service.ts.
    session.fire('error', new Error('peer connection died'))
    await new Promise((r) => setTimeout(r, 0))

    expect(apiFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(String(apiFetch.mock.calls[0]![1]?.body))).toMatchObject({
      audioOutputTokens: 9
    })
  })
})

describe('voice-chat billing wiring — no-deps mode (back-compat)', () => {
  it('omitting deps.billing is a no-op (no crash on response.done or teardown)', async () => {
    const session = makeSession()
    // No billing dep — must still work end-to-end.
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))

    await svc.activate(1, { pageText: 'p' })
    expect(() =>
      session.fire('transport_event', responseDoneEvent({ audioInputTokens: 1 }))
    ).not.toThrow()
    expect(() => svc.deactivate()).not.toThrow()
    expect(svc.getState()).toBe('idle')
  })
})

// Silence unused-import lint via touching the helpers.
void makeIpc
void makeAgent
void makeMedia
void makeWebrtc
void makeConfig
