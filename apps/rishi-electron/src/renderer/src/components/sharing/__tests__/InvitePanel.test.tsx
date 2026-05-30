import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { InvitePanel } from '../InvitePanel'

describe('InvitePanel', () => {
  it('renders the join URL and copies on click', async () => {
    const writeText = vi.fn()
    Object.assign(navigator, { clipboard: { writeText } })
    render(<InvitePanel joinUrl="rishi://sharing/join?t=abc" onSearchUsers={async () => []} onInviteUser={() => {}} />)
    expect(screen.getByDisplayValue('rishi://sharing/join?t=abc')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /copy/i }))
    await waitFor(() => expect(writeText).toHaveBeenCalledWith('rishi://sharing/join?t=abc'))
  })

  it('calls onSearchUsers after typing in the email field', async () => {
    const onSearch = vi.fn(async () => [
      { userId: 'u_z', email: 'z@x.y', displayName: 'Z' }
    ])
    render(<InvitePanel joinUrl="x" onSearchUsers={onSearch} onInviteUser={() => {}} />)
    fireEvent.change(screen.getByLabelText(/email/i), { target: { value: 'z@x.y' } })
    await waitFor(() => expect(onSearch).toHaveBeenCalled(), { timeout: 1000 })
  })
})
