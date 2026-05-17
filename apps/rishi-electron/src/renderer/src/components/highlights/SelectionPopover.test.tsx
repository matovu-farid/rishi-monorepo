import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { SelectionPopover } from './SelectionPopover'
import { HIGHLIGHT_COLORS } from '@/types/highlight'

describe('SelectionPopover', () => {
  const baseProps = {
    cfiRange: 'cfi:x',
    selectedText: 'hello',
    position: { x: 100, y: 100 },
    onHighlight: vi.fn(),
    onClose: vi.fn()
  }

  it('does not render a Read Aloud button when onReadAloudFrom is omitted', () => {
    render(<SelectionPopover {...baseProps} />)
    expect(screen.queryByRole('button', { name: /read aloud/i })).toBeNull()
  })

  it('renders a Read Aloud button when onReadAloudFrom is provided', () => {
    render(<SelectionPopover {...baseProps} onReadAloudFrom={vi.fn()} />)
    expect(screen.getByRole('button', { name: /read aloud/i })).toBeInTheDocument()
  })

  it('clicking the Read Aloud button invokes onReadAloudFrom and onClose', () => {
    const onReadAloudFrom = vi.fn()
    const onClose = vi.fn()
    render(<SelectionPopover {...baseProps} onReadAloudFrom={onReadAloudFrom} onClose={onClose} />)
    fireEvent.click(screen.getByRole('button', { name: /read aloud/i }))
    expect(onReadAloudFrom).toHaveBeenCalledTimes(1)
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  describe('existing-highlight mode (edit/delete)', () => {
    it('does not render Edit/Delete buttons when handlers are omitted', () => {
      render(<SelectionPopover {...baseProps} />)
      expect(screen.queryByRole('button', { name: /edit note/i })).toBeNull()
      expect(screen.queryByRole('button', { name: /delete highlight/i })).toBeNull()
    })

    it('renders Edit and Delete buttons when handlers are provided', () => {
      render(
        <SelectionPopover {...baseProps} onEditNote={vi.fn()} onDelete={vi.fn()} />
      )
      expect(screen.getByRole('button', { name: /edit note/i })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /delete highlight/i })).toBeInTheDocument()
    })

    it('clicking Edit note fires onEditNote and onClose', () => {
      const onEditNote = vi.fn()
      const onClose = vi.fn()
      render(
        <SelectionPopover
          {...baseProps}
          onEditNote={onEditNote}
          onDelete={vi.fn()}
          onClose={onClose}
        />
      )
      fireEvent.click(screen.getByRole('button', { name: /edit note/i }))
      expect(onEditNote).toHaveBeenCalledTimes(1)
      expect(onClose).toHaveBeenCalledTimes(1)
    })

    it('clicking Delete fires onDelete and onClose', () => {
      const onDelete = vi.fn()
      const onClose = vi.fn()
      render(
        <SelectionPopover
          {...baseProps}
          onEditNote={vi.fn()}
          onDelete={onDelete}
          onClose={onClose}
        />
      )
      fireEvent.click(screen.getByRole('button', { name: /delete highlight/i }))
      expect(onDelete).toHaveBeenCalledTimes(1)
      expect(onClose).toHaveBeenCalledTimes(1)
    })

    it('onDelete must work even when the caller-supplied handler captures its target via closure (regression: parent inlinePopover state may be cleared by a sibling popover\'s outside-click race before the click fires)', () => {
      // Simulate: parent renders SelectionPopover with onDelete that
      // captures a cfiRange in a closure (not derived from live state).
      // After render, the parent's state is wiped — yet the captured
      // cfiRange must still drive the delete.
      const deletedCfis: string[] = []
      const capturedCfi = 'cfi:captured'
      const onDelete = () => deletedCfis.push(capturedCfi)
      render(
        <SelectionPopover {...baseProps} onEditNote={vi.fn()} onDelete={onDelete} />
      )
      fireEvent.click(screen.getByRole('button', { name: /delete highlight/i }))
      expect(deletedCfis).toEqual([capturedCfi])
    })

    it('marks the currentColor swatch as active (aria-pressed=true)', () => {
      render(<SelectionPopover {...baseProps} currentColor="green" />)
      for (const c of HIGHLIGHT_COLORS) {
        const swatch = screen.getByRole('button', { name: new RegExp(`highlight.*${c.name}`, 'i') })
        expect(swatch.getAttribute('aria-pressed')).toBe(c.name === 'green' ? 'true' : 'false')
      }
    })
  })

  it('pressing Escape fires onClose', () => {
    const onClose = vi.fn()
    render(<SelectionPopover {...baseProps} onClose={onClose} />)
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onClose).toHaveBeenCalled()
  })
})
