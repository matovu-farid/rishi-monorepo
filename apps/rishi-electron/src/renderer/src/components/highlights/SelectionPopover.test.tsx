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

  describe('fresh-selection add-note path', () => {
    it('renders an "Add note" button when onAddNote is provided (no existing highlight)', () => {
      render(<SelectionPopover {...baseProps} onAddNote={vi.fn()} />)
      expect(screen.getByRole('button', { name: /add note/i })).toBeInTheDocument()
    })

    it('clicking "Add note" on a fresh selection fires onAddNote and onClose', () => {
      const onAddNote = vi.fn()
      const onClose = vi.fn()
      render(<SelectionPopover {...baseProps} onAddNote={onAddNote} onClose={onClose} />)
      fireEvent.click(screen.getByRole('button', { name: /add note/i }))
      expect(onAddNote).toHaveBeenCalledTimes(1)
      expect(onClose).toHaveBeenCalledTimes(1)
    })

    it('color swatches remain visible in fresh-selection mode alongside the Add note button', () => {
      render(<SelectionPopover {...baseProps} onAddNote={vi.fn()} />)
      for (const c of HIGHLIGHT_COLORS) {
        expect(
          screen.getByRole('button', { name: new RegExp(`highlight.*${c.name}`, 'i') })
        ).toBeInTheDocument()
      }
    })

    it('does not render Add note button when onAddNote is omitted', () => {
      render(<SelectionPopover {...baseProps} />)
      expect(screen.queryByRole('button', { name: /add note/i })).toBeNull()
    })

    it('prefers existing-highlight onEditNote over onAddNote when both are provided', () => {
      // When a fresh selection lands on an existing highlight (both flows
      // active), the edit path wins — we don't want to also create a
      // note-only row alongside the existing colored one.
      const onAddNote = vi.fn()
      const onEditNote = vi.fn()
      render(
        <SelectionPopover
          {...baseProps}
          onAddNote={onAddNote}
          onEditNote={onEditNote}
          onDelete={vi.fn()}
        />
      )
      fireEvent.click(screen.getByRole('button', { name: /add note/i }))
      expect(onEditNote).toHaveBeenCalledTimes(1)
      expect(onAddNote).not.toHaveBeenCalled()
    })
  })

  describe('existing-highlight mode (edit/delete)', () => {
    it('does not render note/delete buttons when handlers are omitted', () => {
      render(<SelectionPopover {...baseProps} />)
      expect(screen.queryByRole('button', { name: /add note/i })).toBeNull()
      expect(screen.queryByRole('button', { name: /view note/i })).toBeNull()
      expect(screen.queryByRole('button', { name: /delete highlight/i })).toBeNull()
    })

    it('renders note and Delete buttons when handlers are provided', () => {
      render(<SelectionPopover {...baseProps} onEditNote={vi.fn()} onDelete={vi.fn()} />)
      expect(screen.getByRole('button', { name: /add note/i })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /delete highlight/i })).toBeInTheDocument()
    })

    it('clicking the note button fires onEditNote and onClose', () => {
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
      fireEvent.click(screen.getByRole('button', { name: /add note/i }))
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

    it("onDelete must work even when the caller-supplied handler captures its target via closure (regression: parent inlinePopover state may be cleared by a sibling popover's outside-click race before the click fires)", () => {
      // Simulate: parent renders SelectionPopover with onDelete that
      // captures a cfiRange in a closure (not derived from live state).
      // After render, the parent's state is wiped — yet the captured
      // cfiRange must still drive the delete.
      const deletedCfis: string[] = []
      const capturedCfi = 'cfi:captured'
      const onDelete = () => deletedCfis.push(capturedCfi)
      render(<SelectionPopover {...baseProps} onEditNote={vi.fn()} onDelete={onDelete} />)
      fireEvent.click(screen.getByRole('button', { name: /delete highlight/i }))
      expect(deletedCfis).toEqual([capturedCfi])
    })

    it('note button is labelled "Add note" when hasNote is falsy', () => {
      render(<SelectionPopover {...baseProps} onEditNote={vi.fn()} onDelete={vi.fn()} />)
      expect(screen.getByRole('button', { name: /add note/i })).toBeInTheDocument()
      expect(screen.queryByRole('button', { name: /^view note/i })).toBeNull()
    })

    it('note button is labelled "View note" when hasNote is true (visual indicator that a note exists)', () => {
      render(<SelectionPopover {...baseProps} onEditNote={vi.fn()} onDelete={vi.fn()} hasNote />)
      expect(screen.getByRole('button', { name: /view note/i })).toBeInTheDocument()
      expect(screen.queryByRole('button', { name: /^add note/i })).toBeNull()
    })

    it('clicking the note button fires onEditNote regardless of hasNote', () => {
      const onEditNote = vi.fn()
      const { rerender } = render(
        <SelectionPopover {...baseProps} onEditNote={onEditNote} onDelete={vi.fn()} />
      )
      fireEvent.click(screen.getByRole('button', { name: /add note/i }))
      expect(onEditNote).toHaveBeenCalledTimes(1)

      rerender(
        <SelectionPopover {...baseProps} onEditNote={onEditNote} onDelete={vi.fn()} hasNote />
      )
      fireEvent.click(screen.getByRole('button', { name: /view note/i }))
      expect(onEditNote).toHaveBeenCalledTimes(2)
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
