import { describe, it, expect, beforeEach } from 'vitest'
import { useIndexingStore } from './indexingStore'

describe('indexingStore', () => {
  beforeEach(() => {
    useIndexingStore.getState().reset()
  })

  it('starts with no books being indexed', () => {
    expect(useIndexingStore.getState().byBookId).toEqual({})
    expect(useIndexingStore.getState().getStatus(1)).toBe('idle')
  })

  it('start() seeds total and sets status to running', () => {
    useIndexingStore.getState().start(7, 100)
    const entry = useIndexingStore.getState().byBookId[7]
    expect(entry).toEqual({ done: 0, total: 100, status: 'running' })
  })

  it('advance() increments done up to total', () => {
    useIndexingStore.getState().start(7, 3)
    useIndexingStore.getState().advance(7)
    useIndexingStore.getState().advance(7)
    expect(useIndexingStore.getState().byBookId[7].done).toBe(2)
    expect(useIndexingStore.getState().getStatus(7)).toBe('running')
  })

  it('finish() marks status done and sets done = total', () => {
    useIndexingStore.getState().start(7, 5)
    useIndexingStore.getState().advance(7)
    useIndexingStore.getState().finish(7)
    const entry = useIndexingStore.getState().byBookId[7]
    expect(entry.status).toBe('done')
    expect(entry.done).toBe(entry.total)
  })

  it('error() records the failure', () => {
    useIndexingStore.getState().start(7, 5)
    useIndexingStore.getState().error(7, 'embedding failed')
    const entry = useIndexingStore.getState().byBookId[7]
    expect(entry.status).toBe('error')
    expect(entry.error).toBe('embedding failed')
  })

  it('finish() clears any prior error after a retry', () => {
    const s = useIndexingStore.getState()
    s.start(7, 3)
    s.error(7, 'embedding failed')
    // Retry path: an error is reported, then the same entry recovers and
    // completes without going back through start() (e.g. a transient embedding
    // failure was retried internally). finish() must clear the stale error or
    // consumers reading entry.error independent of entry.status will mis-render.
    s.advance(7)
    s.advance(7)
    s.advance(7)
    s.finish(7)
    const entry = useIndexingStore.getState().byBookId[7]
    expect(entry.status).toBe('done')
    expect(entry.error).toBeUndefined()
  })

  it('isReady() is false while running, true when done', () => {
    expect(useIndexingStore.getState().isReady(7)).toBe(false)
    useIndexingStore.getState().start(7, 2)
    expect(useIndexingStore.getState().isReady(7)).toBe(false)
    useIndexingStore.getState().finish(7)
    expect(useIndexingStore.getState().isReady(7)).toBe(true)
  })

  it('progress() returns done/total ratio, 0 if unknown', () => {
    expect(useIndexingStore.getState().progress(7)).toBe(0)
    useIndexingStore.getState().start(7, 4)
    useIndexingStore.getState().advance(7)
    expect(useIndexingStore.getState().progress(7)).toBe(0.25)
  })
})
