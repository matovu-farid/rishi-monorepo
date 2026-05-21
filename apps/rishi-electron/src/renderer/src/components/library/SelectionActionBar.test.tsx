import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { SelectionActionBar } from './SelectionActionBar'

describe('SelectionActionBar', () => {
  it('renders the count (singular and plural)', () => {
    const { rerender } = render(
      <SelectionActionBar count={1} onSelectAll={() => {}} onDelete={() => {}} onCancel={() => {}} />
    )
    expect(screen.getByText('1 selected')).toBeInTheDocument()
    rerender(
      <SelectionActionBar count={3} onSelectAll={() => {}} onDelete={() => {}} onCancel={() => {}} />
    )
    expect(screen.getByText('3 selected')).toBeInTheDocument()
  })

  it('fires onSelectAll, onDelete, onCancel when clicked', () => {
    const onSelectAll = vi.fn()
    const onDelete = vi.fn()
    const onCancel = vi.fn()
    render(
      <SelectionActionBar
        count={2}
        onSelectAll={onSelectAll}
        onDelete={onDelete}
        onCancel={onCancel}
      />
    )
    fireEvent.click(screen.getByRole('button', { name: /select all/i }))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }))
    expect(onSelectAll).toHaveBeenCalledTimes(1)
    expect(onDelete).toHaveBeenCalledTimes(1)
    expect(onCancel).toHaveBeenCalledTimes(1)
  })

  it('disables Delete when count is 0', () => {
    render(
      <SelectionActionBar count={0} onSelectAll={() => {}} onDelete={() => {}} onCancel={() => {}} />
    )
    expect(screen.getByRole('button', { name: /^delete$/i })).toBeDisabled()
  })
})
