import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { HighlightActionPopover } from './HighlightActionPopover'
import { HIGHLIGHT_COLORS } from '@/types/highlight'

function baseProps() {
  return {
    position: { x: 100, y: 100 },
    currentColor: 'yellow' as const,
    onSelectColor: vi.fn(),
    onEditNote: vi.fn(),
    onDelete: vi.fn(),
    onClose: vi.fn()
  }
}

describe('HighlightActionPopover', () => {
  it('renders a swatch per HIGHLIGHT_COLORS entry, plus Edit note and Delete buttons', () => {
    render(<HighlightActionPopover {...baseProps()} />)
    for (const c of HIGHLIGHT_COLORS) {
      expect(screen.getByRole('button', { name: new RegExp(`change.*${c.name}`, 'i') }))
        .toBeInTheDocument()
    }
    expect(screen.getByRole('button', { name: /edit note/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /delete highlight/i })).toBeInTheDocument()
  })

  it('clicking a color swatch fires onSelectColor and then onClose', () => {
    const props = baseProps()
    const target = HIGHLIGHT_COLORS[0]
    render(<HighlightActionPopover {...props} />)
    fireEvent.click(screen.getByRole('button', { name: new RegExp(`change.*${target.name}`, 'i') }))
    expect(props.onSelectColor).toHaveBeenCalledWith(target.name)
    expect(props.onClose).toHaveBeenCalledTimes(1)
  })

  it('clicking Edit note fires onEditNote and then onClose', () => {
    const props = baseProps()
    render(<HighlightActionPopover {...props} />)
    fireEvent.click(screen.getByRole('button', { name: /edit note/i }))
    expect(props.onEditNote).toHaveBeenCalledTimes(1)
    expect(props.onClose).toHaveBeenCalledTimes(1)
  })

  it('clicking Delete fires onDelete and then onClose', () => {
    const props = baseProps()
    render(<HighlightActionPopover {...props} />)
    fireEvent.click(screen.getByRole('button', { name: /delete highlight/i }))
    expect(props.onDelete).toHaveBeenCalledTimes(1)
    expect(props.onClose).toHaveBeenCalledTimes(1)
  })

  it('pressing Escape fires onClose', () => {
    const props = baseProps()
    render(<HighlightActionPopover {...props} />)
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(props.onClose).toHaveBeenCalled()
  })

  it('clicking outside the popover fires onClose', () => {
    vi.useFakeTimers()
    const props = baseProps()
    render(
      <>
        <div data-testid="outside" />
        <HighlightActionPopover {...props} />
      </>
    )
    vi.advanceTimersByTime(150)
    fireEvent.mouseDown(screen.getByTestId('outside'))
    expect(props.onClose).toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('marks the currentColor swatch as active (aria-pressed=true)', () => {
    render(<HighlightActionPopover {...baseProps()} />)
    const yellowSwatch = screen.getByRole('button', { name: /change.*yellow/i })
    expect(yellowSwatch.getAttribute('aria-pressed')).toBe('true')
  })
})
