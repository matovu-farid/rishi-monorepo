import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { SelectionPopover } from './SelectionPopover'

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
    render(
      <SelectionPopover {...baseProps} onReadAloudFrom={onReadAloudFrom} onClose={onClose} />
    )
    fireEvent.click(screen.getByRole('button', { name: /read aloud/i }))
    expect(onReadAloudFrom).toHaveBeenCalledTimes(1)
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
