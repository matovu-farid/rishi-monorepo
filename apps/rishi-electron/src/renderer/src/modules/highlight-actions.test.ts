import { describe, it, expect, vi, beforeEach } from 'vitest'

vi.mock('@/modules/highlight-storage', () => ({
  saveHighlight: vi.fn().mockResolvedValue('hl-1'),
  deleteHighlight: vi.fn().mockResolvedValue(undefined)
}))

vi.mock('@/services', () => ({
  getSyncService: vi.fn(() => ({ triggerWrite: vi.fn() }))
}))

import { saveHighlight, deleteHighlight } from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import { applyHighlightWithUndo, deleteHighlightWithUndo } from './highlight-actions'

function makeTarget() {
  return {
    applyVisual: vi.fn(),
    removeVisual: vi.fn()
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite: vi.fn() })
})

describe('applyHighlightWithUndo — apply path', () => {
  it('calls applyVisual, saveHighlight and triggerWrite exactly once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })

    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledWith({
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })
})

describe('applyHighlightWithUndo — undo path', () => {
  it('handle.undo() calls removeVisual, deleteHighlight and triggerWrite once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow'
    })

    // Reset counts so we only see undo-time activity.
    target.applyVisual.mockClear()
    ;(saveHighlight as unknown as ReturnType<typeof vi.fn>).mockClear()
    triggerWrite.mockClear()

    await handle.undo()

    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledWith('book-2', 'cfi:2')
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('returns a working handle even if saveHighlight rejects', async () => {
    ;(saveHighlight as unknown as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('boom'))
    const target = makeTarget()
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-3',
      cfiRange: 'cfi:3',
      text: 'x',
      color: 'yellow'
    })

    expect(warn).toHaveBeenCalled()
    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    await handle.undo()
    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    warn.mockRestore()
  })

  it('calling undo twice is safe — second call still removes visual but does not throw', async () => {
    const target = makeTarget()
    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-4',
      cfiRange: 'cfi:4',
      text: 'x',
      color: 'yellow'
    })

    await handle.undo()
    await expect(handle.undo()).resolves.toBeUndefined()
    expect(target.removeVisual).toHaveBeenCalledTimes(2)
  })
})

describe('deleteHighlightWithUndo — delete path', () => {
  it('calls removeVisual, deleteHighlight and triggerWrite exactly once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })

    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledWith('book-1', 'cfi:1')
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('handle.undo() calls applyVisual, saveHighlight and triggerWrite once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow',
      note: 'a note'
    })

    target.removeVisual.mockClear()
    ;(deleteHighlight as unknown as ReturnType<typeof vi.fn>).mockClear()
    triggerWrite.mockClear()

    await handle.undo()

    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledWith({
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow',
      note: 'a note',
      chapter: undefined
    })
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('returns a working handle even if deleteHighlight rejects', async () => {
    ;(deleteHighlight as unknown as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('boom'))
    const target = makeTarget()
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-3',
      cfiRange: 'cfi:3',
      text: 'x',
      color: 'yellow'
    })

    expect(warn).toHaveBeenCalled()
    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    await handle.undo()
    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    warn.mockRestore()
  })

  it('calling undo twice is safe — second call still re-applies visual but does not throw', async () => {
    const target = makeTarget()
    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-4',
      cfiRange: 'cfi:4',
      text: 'x',
      color: 'yellow'
    })

    await handle.undo()
    await expect(handle.undo()).resolves.toBeUndefined()
    expect(target.applyVisual).toHaveBeenCalledTimes(2)
  })
})
