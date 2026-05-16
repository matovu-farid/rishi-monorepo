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
import { applyHighlightWithUndo } from './highlight-actions'

function makeTarget() {
  return {
    applyVisual: vi.fn(),
    removeVisual: vi.fn()
  }
}

beforeEach(() => {
  vi.clearAllMocks()
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
