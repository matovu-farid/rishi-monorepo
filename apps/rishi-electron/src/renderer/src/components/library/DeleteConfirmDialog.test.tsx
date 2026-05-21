import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { DeleteConfirmDialog } from './DeleteConfirmDialog'

describe('DeleteConfirmDialog', () => {
  it('does not render when closed', () => {
    render(
      <DeleteConfirmDialog
        open={false}
        count={3}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    expect(screen.queryByText(/delete/i)).not.toBeInTheDocument()
  })

  it('renders the count in the title (singular and plural)', () => {
    const { rerender } = render(
      <DeleteConfirmDialog
        open={true}
        count={1}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    expect(screen.getByText('Delete 1 book?')).toBeInTheDocument()
    rerender(
      <DeleteConfirmDialog
        open={true}
        count={5}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    expect(screen.getByText('Delete 5 books?')).toBeInTheDocument()
  })

  it('fires onConfirm when Delete is clicked', () => {
    const onConfirm = vi.fn()
    render(
      <DeleteConfirmDialog
        open={true}
        count={2}
        onCancel={() => {}}
        onConfirm={onConfirm}
        isDeleting={false}
      />
    )
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it('fires onCancel when Cancel is clicked', () => {
    const onCancel = vi.fn()
    render(
      <DeleteConfirmDialog
        open={true}
        count={2}
        onCancel={onCancel}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(onCancel).toHaveBeenCalledTimes(1)
  })

  it('disables the Delete button while deleting', () => {
    render(
      <DeleteConfirmDialog
        open={true}
        count={2}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={true}
      />
    )
    expect(screen.getByRole('button', { name: /deleting/i })).toBeDisabled()
  })
})
