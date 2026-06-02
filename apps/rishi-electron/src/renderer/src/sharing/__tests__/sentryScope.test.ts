import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => {
  const setTag = vi.fn()
  const setExtras = vi.fn()
  const captureException = vi.fn()
  const addBreadcrumb = vi.fn()
  const withScope = vi.fn((cb: (s: unknown) => void) => cb({ setTag, setExtras }))
  const configureScope = vi.fn((cb: (s: unknown) => void) => cb({ setTag }))
  return { setTag, setExtras, captureException, addBreadcrumb, withScope, configureScope }
})

vi.mock('@sentry/electron/renderer', () => ({
  withScope: mocks.withScope,
  addBreadcrumb: mocks.addBreadcrumb,
  captureException: mocks.captureException,
  configureScope: mocks.configureScope
}))

import {
  clearSharingFeatureTag,
  recordSharingBreadcrumb,
  recordSharingError,
  setSharingFeatureTag,
  withSharingScope
} from '../sentryScope'

beforeEach(() => {
  mocks.captureException.mockClear()
  mocks.addBreadcrumb.mockClear()
  mocks.setTag.mockClear()
  mocks.setExtras.mockClear()
  mocks.withScope.mockClear()
  mocks.configureScope.mockClear()
  mocks.withScope.mockImplementation((cb: (s: unknown) => void) =>
    cb({ setTag: mocks.setTag, setExtras: mocks.setExtras })
  )
  mocks.configureScope.mockImplementation((cb: (s: unknown) => void) =>
    cb({ setTag: mocks.setTag })
  )
})

describe('withSharingScope', () => {
  it('tags the scope with feature=sharing and returns the callback result', () => {
    const out = withSharingScope(() => 42)
    expect(out).toBe(42)
    expect(mocks.setTag).toHaveBeenCalledWith('feature', 'sharing')
  })

  it('attaches extra tags and extras when provided', () => {
    withSharingScope(() => undefined, {
      tags: { actor: 'peerActor' },
      extras: { sessionId: 'abc' }
    })
    expect(mocks.setTag).toHaveBeenCalledWith('feature', 'sharing')
    expect(mocks.setTag).toHaveBeenCalledWith('actor', 'peerActor')
    expect(mocks.setExtras).toHaveBeenCalledWith({ sessionId: 'abc' })
  })

  it('falls back to invoking the callback if Sentry throws', () => {
    mocks.withScope.mockImplementationOnce(() => {
      throw new Error('boom')
    })
    const out = withSharingScope(() => 'ok')
    expect(out).toBe('ok')
  })
})

describe('recordSharingError', () => {
  it('tags the error with feature=sharing and forwards to captureException', () => {
    const err = new Error('signaling dropped')
    recordSharingError(err, { code: 1006 })
    expect(mocks.setTag).toHaveBeenCalledWith('feature', 'sharing')
    expect(mocks.setExtras).toHaveBeenCalledWith({ code: 1006 })
    expect(mocks.captureException).toHaveBeenCalledWith(err)
  })

  it('lifts actor extra to a tag for the runbook actor=fileTransferActor query', () => {
    recordSharingError(new Error('x'), { actor: 'fileTransferActor', reason: 'hash_mismatch' })
    expect(mocks.setTag).toHaveBeenCalledWith('actor', 'fileTransferActor')
  })

  it('wraps non-Error throwables in an Error', () => {
    recordSharingError('plain string')
    const arg = mocks.captureException.mock.calls[0]?.[0]
    expect(arg).toBeInstanceOf(Error)
    expect((arg as Error).message).toBe('plain string')
  })

  it('never throws when Sentry itself throws', () => {
    mocks.withScope.mockImplementationOnce(() => {
      throw new Error('sentry broken')
    })
    expect(() => recordSharingError(new Error('x'))).not.toThrow()
  })
})

describe('recordSharingBreadcrumb', () => {
  it('adds a breadcrumb with category sharing and given message', () => {
    recordSharingBreadcrumb('peer.ice_failed', { state: 'failed' })
    expect(mocks.addBreadcrumb).toHaveBeenCalledWith({
      category: 'sharing',
      message: 'peer.ice_failed',
      data: { state: 'failed' },
      level: 'info'
    })
  })

  it('silently no-ops when the SDK throws', () => {
    mocks.addBreadcrumb.mockImplementationOnce(() => {
      throw new Error('nope')
    })
    expect(() => recordSharingBreadcrumb('whatever')).not.toThrow()
  })
})

describe('setSharingFeatureTag / clearSharingFeatureTag', () => {
  it('sets feature=sharing on the global scope', () => {
    setSharingFeatureTag()
    expect(mocks.setTag).toHaveBeenCalledWith('feature', 'sharing')
  })

  it('clears feature tag by setting it to undefined', () => {
    clearSharingFeatureTag()
    expect(mocks.setTag).toHaveBeenCalledWith('feature', undefined)
  })

  it('never throws when the SDK throws', () => {
    mocks.configureScope.mockImplementationOnce(() => {
      throw new Error('boom')
    })
    expect(() => setSharingFeatureTag()).not.toThrow()
  })
})
