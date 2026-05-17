/**
 * NoteEditor tests focused on the save-flow contract.
 *
 * The critical contract: `handleSave` must AWAIT `onSaved` before calling
 * `onOpenChange(false)`. The parent's onSaved typically refreshes the in-
 * memory highlights map; the parent's onOpenChange runs orphan-cleanup
 * that checks that same map. If onOpenChange runs first, the cleanup sees
 * stale state and deletes the freshly-saved row — the "icon never appears"
 * bug.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const updateHighlightNoteMock = vi.fn().mockResolvedValue(undefined)

vi.mock('@/modules/highlight-storage', () => ({
  updateHighlightNote: (...args: unknown[]) => updateHighlightNoteMock(...args)
}))

vi.mock('@/services', () => ({
  getSyncService: vi.fn(() => ({ triggerWrite: vi.fn() }))
}))

import { NoteEditor } from './NoteEditor'
import type { HighlightRow } from '@/modules/highlight-storage'

function row(over: Partial<HighlightRow> = {}): HighlightRow {
  return {
    id: 'row-1',
    bookId: 'book-1',
    cfiRange: 'cfi:1',
    text: 'sample',
    color: 'none',
    note: '',
    chapter: null,
    createdAt: '0',
    updatedAt: 0,
    syncId: null,
    syncVersion: 0,
    isDirty: 1,
    isDeleted: 0,
    ...over
  }
}

describe('NoteEditor save flow', () => {
  it('awaits onSaved before calling onOpenChange so the parent can refresh state in a race-free way', async () => {
    const onOpenChange = vi.fn()
    let resolveSaved!: () => void
    const onSaved = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveSaved = resolve
        })
    )

    render(<NoteEditor highlight={row()} open onOpenChange={onOpenChange} onSaved={onSaved} />)

    const textarea = screen.getByPlaceholderText('Add a note...')
    fireEvent.change(textarea, { target: { value: 'my thought' } })
    fireEvent.click(screen.getByRole('button', { name: /save note/i }))

    // Let microtasks run so updateHighlightNote resolves and onSaved is invoked.
    await Promise.resolve()
    await Promise.resolve()

    // onSaved was called but onOpenChange must NOT have been called yet.
    // If onOpenChange fires before the parent's onSaved completes, the
    // parent's orphan-cleanup will run against stale state and delete the
    // freshly-saved row.
    expect(onSaved).toHaveBeenCalledTimes(1)
    expect(onOpenChange).not.toHaveBeenCalled()

    // After onSaved resolves, the close handler fires.
    resolveSaved()
    await Promise.resolve()
    await Promise.resolve()
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it('still calls onOpenChange(false) even if onSaved is synchronous (no regression for callers returning void)', async () => {
    const onOpenChange = vi.fn()
    const onSaved = vi.fn() // returns undefined, not a promise

    render(<NoteEditor highlight={row()} open onOpenChange={onOpenChange} onSaved={onSaved} />)

    fireEvent.change(screen.getByPlaceholderText('Add a note...'), {
      target: { value: 'sync save' }
    })
    fireEvent.click(screen.getByRole('button', { name: /save note/i }))

    // Drain the await chain.
    await Promise.resolve()
    await Promise.resolve()
    await Promise.resolve()
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })
})
