import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { SessionPanel } from '../SessionPanel'

const baseProps = {
  role: 'host' as const,
  selfUserId: 'u_a',
  sharerId: 'u_a',
  participants: [
    {
      userId: 'u_a', profile: { displayName: 'Me' },
      joinedAt: 1, hasBookFile: true,
      micState: 'unmuted' as const, connectionState: 'connected' as const
    },
    {
      userId: 'u_b', profile: { displayName: 'B' },
      joinedAt: 2, hasBookFile: true,
      micState: 'unmuted' as const, connectionState: 'connected' as const
    }
  ],
  pendingJoiners: [{ userId: 'u_c', profile: { displayName: 'C' } }],
  joinUrl: 'rishi://x',
  fileTransfers: [],
  onSearchUsers: async () => [],
  onInviteUser: () => {},
  onApprove: () => {},
  onReject: () => {},
  onMute: () => {},
  onUnmute: () => {},
  onPassSharer: () => {},
  onKick: () => {}
}

describe('SessionPanel', () => {
  it('renders participants and pending joiners', () => {
    render(<SessionPanel {...baseProps} />)
    expect(screen.getByText(/Me/)).toBeInTheDocument()
    // Participant "B" appears both as avatar initial and display name;
    // assert at least one occurrence.
    expect(screen.getAllByText(/^B/).length).toBeGreaterThan(0)
    expect(screen.getByText(/^C$/)).toBeInTheDocument()
  })

  it('hides the host menu for viewers', () => {
    render(<SessionPanel {...baseProps} role="viewer" />)
    expect(screen.queryByRole('button', { name: /Kick/i })).not.toBeInTheDocument()
  })
})
