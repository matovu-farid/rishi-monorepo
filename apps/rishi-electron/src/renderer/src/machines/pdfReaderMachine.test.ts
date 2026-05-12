import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createActor, fromPromise } from 'xstate'
import { pdfReaderMachine } from './pdfReaderMachine'

function createTestActor(opts?: {
  initialPage?: number
  saveImpl?: (input: { bookId: number; page: number }) => Promise<{ savedPage: number }>
}) {
  const saveImpl =
    opts?.saveImpl ?? (async ({ page }) => ({ savedPage: page }))
  const machine = pdfReaderMachine.provide({
    actors: {
      saveLocation: fromPromise<{ savedPage: number }, { bookId: number; page: number }>(
        ({ input }) => saveImpl(input)
      )
    }
  })
  return createActor(machine, {
    input: { bookId: 42, initialPage: opts?.initialPage ?? 50 }
  })
}

describe('pdfReaderMachine', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts in seek.idle and persist.clean', () => {
    const actor = createTestActor()
    actor.start()
    expect(actor.getSnapshot().value).toEqual({ seek: 'idle', persist: 'clean' })
    expect(actor.getSnapshot().context.currentPage).toBe(50)
    expect(actor.getSnapshot().context.lastSaved).toBe(50)
  })

  it('DOC_LOADED moves seek to seeking with seekTarget = initialPage', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'seeking', persist: 'clean' })
    expect(snap.context.seekTarget).toBe(50)
    expect(snap.context.numPages).toBe(200)
  })

  it('clamps initialPage to numPages on DOC_LOADED', () => {
    const actor = createTestActor({ initialPage: 999 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    expect(actor.getSnapshot().context.seekTarget).toBe(200)
  })

  it('SEEK_LANDED transitions to viewing and updates currentPage', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'viewing', persist: 'clean' })
    expect(snap.context.currentPage).toBe(50)
    expect(snap.context.seekTarget).toBeNull()
  })

  // Regression for the original bug: scroll detector reads sentinel "1" while
  // seek is in flight and stomps the saved location.
  it('PAGE_CHANGED during seeking does NOT mark persist dirty or change currentPage', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'seeking', persist: 'clean' })
    actor.send({ type: 'PAGE_CHANGED', page: 1 })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'seeking', persist: 'clean' })
    expect(snap.context.currentPage).toBe(50)
  })

  it('PAGE_CHANGED during viewing updates currentPage and marks persist dirty', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75 })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(snap.context.currentPage).toBe(75)
  })

  it('SEEK_REQUESTED from viewing transitions back to seeking', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'SEEK_REQUESTED', page: 100 })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'seeking', persist: 'clean' })
    expect(snap.context.seekTarget).toBe(100)
  })

  it('persist.dirty advances to saving after the debounce delay', async () => {
    const saveSpy = vi.fn(async ({ page }) => ({ savedPage: page }))
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'dirty' })

    await vi.advanceTimersByTimeAsync(400)

    expect(saveSpy).toHaveBeenCalledOnce()
    expect(saveSpy).toHaveBeenCalledWith({ bookId: 42, page: 75 })
    // After save resolves, persist returns to clean and lastSaved advances
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })
    expect(actor.getSnapshot().context.lastSaved).toBe(75)
  })

  it('PAGE_CHANGED while dirty resets the debounce timer (only one save)', async () => {
    const saveSpy = vi.fn(async ({ page }) => ({ savedPage: page }))
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 60 })
    await vi.advanceTimersByTimeAsync(200)
    actor.send({ type: 'PAGE_CHANGED', page: 70 })
    await vi.advanceTimersByTimeAsync(200) // total 400 since first, but timer reset
    expect(saveSpy).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(200) // 400 since the second change
    expect(saveSpy).toHaveBeenCalledOnce()
    expect(saveSpy).toHaveBeenCalledWith({ bookId: 42, page: 70 })
  })

  it('skips save if PAGE_CHANGED page equals lastSaved', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    // Land at 50, lastSaved is 50. Manual scroll back to 50 (e.g. virtualizer
    // jitter) shouldn't dirty.
    actor.send({ type: 'PAGE_CHANGED', page: 50 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })
  })

  it('if user scrolls during saving, transitions back to dirty after save completes', async () => {
    let resolveSave: (() => void) | null = null
    const saveImpl = (input: { bookId: number; page: number }) =>
      new Promise<{ savedPage: number }>((resolve) => {
        resolveSave = () => resolve({ savedPage: input.page })
      })
    const actor = createTestActor({ initialPage: 50, saveImpl })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 60 })
    await vi.advanceTimersByTimeAsync(400)
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'saving' })
    // While saving, user scrolls further
    actor.send({ type: 'PAGE_CHANGED', page: 80 })
    expect(actor.getSnapshot().context.currentPage).toBe(80)
    // Save completes for page 60
    resolveSave!()
    // Flush microtasks so the actor processes the done event under fake timers
    await Promise.resolve()
    await Promise.resolve()
    await vi.advanceTimersByTimeAsync(0)
    // Should be back to dirty (because currentPage 80 !== savedPage 60)
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(snap.context.lastSaved).toBe(60)
  })

  it('FLUSH event invokes the flush callback when current differs from lastSaved', () => {
    const flushSpy = vi.fn()
    const machine = pdfReaderMachine.provide({
      actors: {
        saveLocation: fromPromise<{ savedPage: number }, { bookId: number; page: number }>(
          async ({ input }) => ({ savedPage: input.page })
        )
      },
      actions: {
        flushSave: ({ context }) => flushSpy(context.currentPage)
      }
    })
    const actor = createActor(machine, { input: { bookId: 1, initialPage: 50 } })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75 })
    actor.send({ type: 'FLUSH' })
    expect(flushSpy).toHaveBeenCalledWith(75)
  })

  it('FLUSH does nothing when persist is clean', () => {
    const flushSpy = vi.fn()
    const machine = pdfReaderMachine.provide({
      actors: {
        saveLocation: fromPromise<{ savedPage: number }, { bookId: number; page: number }>(
          async ({ input }) => ({ savedPage: input.page })
        )
      },
      actions: {
        flushSave: () => flushSpy()
      }
    })
    const actor = createActor(machine, { input: { bookId: 1, initialPage: 50 } })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'FLUSH' })
    expect(flushSpy).not.toHaveBeenCalled()
  })

  // Regression for the "TOC/thumbnail navigation doesn't save" bug. Every
  // user-initiated jump must end up persisted, not just scroll-driven changes.
  it('SEEK_REQUESTED + SEEK_LANDED triggers a save when target differs from lastSaved', async () => {
    const saveSpy = vi.fn(async ({ page }) => ({ savedPage: page }))
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' }) // initial restore, no save expected
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })

    // User clicks thumbnail / TOC entry for page 100
    actor.send({ type: 'SEEK_REQUESTED', page: 100 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'seeking', persist: 'clean' })
    actor.send({ type: 'SEEK_LANDED' })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(actor.getSnapshot().context.currentPage).toBe(100)

    await vi.advanceTimersByTimeAsync(400)
    expect(saveSpy).toHaveBeenCalledOnce()
    expect(saveSpy).toHaveBeenCalledWith({ bookId: 42, page: 100 })
  })

  // Initial restore from book.location lands at the saved page; no save needed.
  it('initial DOC_LOADED + SEEK_LANDED does NOT trigger a save', async () => {
    const saveSpy = vi.fn(async ({ page }) => ({ savedPage: page }))
    const actor = createTestActor({ initialPage: 75, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })

    await vi.advanceTimersByTimeAsync(400)
    expect(saveSpy).not.toHaveBeenCalled()
  })

  it('save error transitions back to dirty for retry', async () => {
    const saveSpy = vi
      .fn()
      .mockRejectedValueOnce(new Error('IPC down'))
      .mockResolvedValueOnce({ savedPage: 75 })
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75 })
    await vi.advanceTimersByTimeAsync(400)
    // First attempt rejected → back to dirty
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(actor.getSnapshot().context.saveError).toBe('Error: IPC down')
    await vi.advanceTimersByTimeAsync(400)
    // Second attempt resolves → clean
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })
    expect(actor.getSnapshot().context.lastSaved).toBe(75)
  })
})
