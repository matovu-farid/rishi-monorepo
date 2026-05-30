import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ApprovalWaitingScreen } from '../ApprovalWaitingScreen'

describe('ApprovalWaitingScreen', () => {
  it('renders waiting copy', () => {
    render(<ApprovalWaitingScreen hostName="Alex" onCancel={() => {}} />)
    expect(screen.getByText(/Waiting for Alex/i)).toBeInTheDocument()
  })

  it('fires onCancel when Cancel pressed', () => {
    const onCancel = vi.fn()
    render(<ApprovalWaitingScreen hostName="A" onCancel={onCancel} />)
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }))
    expect(onCancel).toHaveBeenCalled()
  })
})
