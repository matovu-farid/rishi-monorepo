import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createActor, fromPromise } from 'xstate'
import { pdfReaderMachine } from './pdfReaderMachine'

type SaveInput = { bookId: number; page: number; offset: number }
type SaveOutput = { savedPage: number; savedOffset: number }

function createTestActor(opts?: {
  initialPage?: number
  initialOffset?: number
  saveImpl?: (input: SaveInput) => Promise<SaveOutput>
}) {
  const saveImpl =
    opts?.saveImpl ??
    (async ({ page, offset }) => ({ savedPage: page, savedOffset: offset }))
  const machine = pdfReaderMachine.provide({
    actors: {
      saveLocation: fromPromise<SaveOutput, SaveInput>(({ input }) => saveImpl(input))
    }
  })
  return createActor(machine, {
    input: {
      bookId: 42,
      initialPage: opts?.initialPage ?? 50,
      initialOffset: opts?.initialOffset ?? 0
    }
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
    expect(actor.getSnapshot().context.lastSavedPage).toBe(50)
  })

  it('seeds currentOffset and pendingOffset from input.initialOffset', () => {
    const actor = createTestActor({ initialPage: 50, initialOffset: 240 })
    actor.start()
    const ctx = actor.getSnapshot().context
    expect(ctx.currentOffset).toBe(240)
    expect(ctx.pendingOffset).toBe(240)
    expect(ctx.lastSavedOffset).toBe(240)
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

  it('SEEK_LANDED moves pendingOffset → currentOffset and clears pending', () => {
    const actor = createTestActor({ initialPage: 50, initialOffset: 240 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    const ctx = actor.getSnapshot().context
    expect(ctx.currentOffset).toBe(240)
    expect(ctx.pendingOffset).toBe(0)
  })

  it('a fresh SEEK_REQUESTED clears pendingOffset (jump-to-page lands at top)', () => {
    const actor = createTestActor({ initialPage: 50, initialOffset: 240 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_REQUESTED', page: 100 })
    expect(actor.getSnapshot().context.pendingOffset).toBe(0)
  })

  // Regression for the original bug: scroll detector reads sentinel "1" while
  // seek is in flight and stomps the saved location.
  it('PAGE_CHANGED during seeking does NOT mark persist dirty or change currentPage', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'seeking', persist: 'clean' })
    actor.send({ type: 'PAGE_CHANGED', page: 1, offset: 0 })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'seeking', persist: 'clean' })
    expect(snap.context.currentPage).toBe(50)
  })

  it('PAGE_CHANGED during viewing updates currentPage and marks persist dirty', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75, offset: 0 })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(snap.context.currentPage).toBe(75)
  })

  it('PAGE_CHANGED with same page but new offset still dirties persist', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 50, offset: 320 })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(snap.context.currentOffset).toBe(320)
  })

  it('PAGE_CHANGED with same page and offset within threshold stays clean', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 50, offset: 8 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })
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
    const saveSpy = vi.fn(async ({ page, offset }: SaveInput) => ({
      savedPage: page,
      savedOffset: offset
    }))
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75, offset: 120 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'dirty' })

    await vi.advanceTimersByTimeAsync(400)

    expect(saveSpy).toHaveBeenCalledOnce()
    expect(saveSpy).toHaveBeenCalledWith({ bookId: 42, page: 75, offset: 120 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })
    expect(actor.getSnapshot().context.lastSavedPage).toBe(75)
    expect(actor.getSnapshot().context.lastSavedOffset).toBe(120)
  })

  it('PAGE_CHANGED while dirty resets the debounce timer (only one save)', async () => {
    const saveSpy = vi.fn(async ({ page, offset }: SaveInput) => ({
      savedPage: page,
      savedOffset: offset
    }))
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 60, offset: 0 })
    await vi.advanceTimersByTimeAsync(200)
    actor.send({ type: 'PAGE_CHANGED', page: 70, offset: 0 })
    await vi.advanceTimersByTimeAsync(200) // total 400 since first, but timer reset
    expect(saveSpy).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(200) // 400 since the second change
    expect(saveSpy).toHaveBeenCalledOnce()
    expect(saveSpy).toHaveBeenCalledWith({ bookId: 42, page: 70, offset: 0 })
  })

  it('skips save if PAGE_CHANGED page+offset equals last saved', () => {
    const actor = createTestActor({ initialPage: 50 })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 50, offset: 0 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })
  })

  it('if user scrolls during saving, transitions back to dirty after save completes', async () => {
    let resolveSave: (() => void) | null = null
    const saveImpl = (input: SaveInput) =>
      new Promise<SaveOutput>((resolve) => {
        resolveSave = () => resolve({ savedPage: input.page, savedOffset: input.offset })
      })
    const actor = createTestActor({ initialPage: 50, saveImpl })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 60, offset: 0 })
    await vi.advanceTimersByTimeAsync(400)
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'saving' })
    actor.send({ type: 'PAGE_CHANGED', page: 80, offset: 0 })
    expect(actor.getSnapshot().context.currentPage).toBe(80)
    resolveSave!()
    await Promise.resolve()
    await Promise.resolve()
    await vi.advanceTimersByTimeAsync(0)
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(snap.context.lastSavedPage).toBe(60)
  })

  it('FLUSH event invokes the flush callback when current differs from lastSaved', () => {
    const flushSpy = vi.fn()
    const machine = pdfReaderMachine.provide({
      actors: {
        saveLocation: fromPromise<SaveOutput, SaveInput>(async ({ input }) => ({
          savedPage: input.page,
          savedOffset: input.offset
        }))
      },
      actions: {
        flushSave: ({ context }) => flushSpy(context.currentPage, context.currentOffset)
      }
    })
    const actor = createActor(machine, {
      input: { bookId: 1, initialPage: 50, initialOffset: 0 }
    })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75, offset: 200 })
    actor.send({ type: 'FLUSH' })
    expect(flushSpy).toHaveBeenCalledWith(75, 200)
  })

  it('FLUSH does nothing when persist is clean', () => {
    const flushSpy = vi.fn()
    const machine = pdfReaderMachine.provide({
      actors: {
        saveLocation: fromPromise<SaveOutput, SaveInput>(async ({ input }) => ({
          savedPage: input.page,
          savedOffset: input.offset
        }))
      },
      actions: {
        flushSave: () => flushSpy()
      }
    })
    const actor = createActor(machine, {
      input: { bookId: 1, initialPage: 50, initialOffset: 0 }
    })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'FLUSH' })
    expect(flushSpy).not.toHaveBeenCalled()
  })

  // Regression for the "TOC/thumbnail navigation doesn't save" bug. Every
  // user-initiated jump must end up persisted, not just scroll-driven changes.
  it('SEEK_REQUESTED + SEEK_LANDED triggers a save when target differs from lastSaved', async () => {
    const saveSpy = vi.fn(async ({ page, offset }: SaveInput) => ({
      savedPage: page,
      savedOffset: offset
    }))
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' }) // initial restore, no save expected
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })

    actor.send({ type: 'SEEK_REQUESTED', page: 100 })
    expect(actor.getSnapshot().value).toEqual({ seek: 'seeking', persist: 'clean' })
    actor.send({ type: 'SEEK_LANDED' })
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(actor.getSnapshot().context.currentPage).toBe(100)

    await vi.advanceTimersByTimeAsync(400)
    expect(saveSpy).toHaveBeenCalledOnce()
    expect(saveSpy).toHaveBeenCalledWith({ bookId: 42, page: 100, offset: 0 })
  })

  // Initial restore from book.location lands at the saved page; no save needed.
  it('initial DOC_LOADED + SEEK_LANDED does NOT trigger a save', async () => {
    const saveSpy = vi.fn(async ({ page, offset }: SaveInput) => ({
      savedPage: page,
      savedOffset: offset
    }))
    const actor = createTestActor({ initialPage: 75, initialOffset: 200, saveImpl: saveSpy })
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
      .mockResolvedValueOnce({ savedPage: 75, savedOffset: 0 })
    const actor = createTestActor({ initialPage: 50, saveImpl: saveSpy })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 200 })
    actor.send({ type: 'SEEK_LANDED' })
    actor.send({ type: 'PAGE_CHANGED', page: 75, offset: 0 })
    await vi.advanceTimersByTimeAsync(400)
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'dirty' })
    expect(actor.getSnapshot().context.saveError).toBe('Error: IPC down')
    await vi.advanceTimersByTimeAsync(400)
    expect(actor.getSnapshot().value).toEqual({ seek: 'viewing', persist: 'clean' })
    expect(actor.getSnapshot().context.lastSavedPage).toBe(75)
  })
})
