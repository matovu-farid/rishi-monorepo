import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'

vi.mock('@/lib/sharing-flag', () => ({
  isSharingEnabled: () => true,
  isSharingEnabledForUser: () => true
}))

// Stub the session machine hook directly so we don't have to spin up xstate
// from scratch. The overlay only reads `state.value`, `state.context`, and
// `send` — a static snapshot is enough to assert which children mount.
const sendMock = vi.fn()
let mockSnapshot: { value: unknown; context: Record<string, unknown> } = {
  value: 'idle',
  context: {
    participants: new Map(),
    pendingJoiners: new Map(),
    receivedBooks: [],
    role: 'host',
    sharerId: null,
    me: null,
    joinUrl: null,
    error: null
  }
}

vi.mock('@/hooks/useSessionMachine', () => ({
  useSessionMachine: () => ({
    state: mockSnapshot,
    send: sendMock,
    actorRef: null
  }),
  SessionMachineProvider: ({ children }: { children: React.ReactNode }) => children
}))

// Re-import so the mocks above resolve.
import { SharingSessionOverlay } from '../SharingSessionOverlay'

describe('SharingSessionOverlay', () => {
  beforeEach(() => {
    sendMock.mockReset()
  })

  it('renders nothing when machine is idle', () => {
    mockSnapshot = {
      value: 'idle',
      context: {
        participants: new Map(),
        pendingJoiners: new Map(),
        receivedBooks: [],
        role: 'host',
        sharerId: null,
        me: null,
        joinUrl: null,
        error: null
      }
    }
    const { container } = render(<SharingSessionOverlay />)
    expect(container).toBeEmptyDOMElement()
  })

  it('renders SessionPanel when state is connected.live with participants', () => {
    const participants = new Map<string, { userId: string; profile: { displayName: string }; joinedAt: number; hasBookFile: boolean; micState: string; connectionState: string }>([
      [
        'host-1',
        {
          userId: 'host-1',
          profile: { displayName: 'Alex' },
          joinedAt: 0,
          hasBookFile: true,
          micState: 'unmuted',
          connectionState: 'connected'
        }
      ],
      [
        'viewer-1',
        {
          userId: 'viewer-1',
          profile: { displayName: 'Sam' },
          joinedAt: 1,
          hasBookFile: false,
          micState: 'unmuted',
          connectionState: 'connected'
        }
      ]
    ])
    mockSnapshot = {
      value: {
        connected: {
          live: {
            roster: {},
            hostControl: {},
            selfState: {},
            hostStatus: 'normal'
          }
        }
      },
      context: {
        participants,
        pendingJoiners: new Map(),
        receivedBooks: [],
        role: 'host',
        sharerId: 'host-1',
        me: { userId: 'host-1', displayName: 'Alex', authToken: 'jwt' },
        joinUrl: 'https://example.com/join?token=abc',
        error: null
      }
    }
    render(<SharingSessionOverlay />)
    expect(screen.getByRole('complementary', { name: /shared reading session/i })).toBeInTheDocument()
    // ParticipantTile renders the self user as "<name> (you)" and others as
    // the bare name — match each independently.
    expect(screen.getByText(/Alex/)).toBeInTheDocument()
    expect(screen.getByText('Sam')).toBeInTheDocument()
  })

  it('renders KickedDialog when state is failed with error.code kicked', () => {
    mockSnapshot = {
      value: 'failed',
      context: {
        participants: new Map(),
        pendingJoiners: new Map(),
        receivedBooks: [],
        role: 'viewer',
        sharerId: null,
        me: { userId: 'viewer-1', displayName: 'Sam', authToken: 'jwt' },
        joinUrl: null,
        error: { code: 'kicked', message: 'You were removed by the host.', recoverable: false }
      }
    }
    render(<SharingSessionOverlay />)
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(screen.getByText(/removed by the host/i)).toBeInTheDocument()
  })

  it('renders HostSuspendedBanner with the expected testid when hostStatus is suspended', () => {
    mockSnapshot = {
      value: {
        connected: {
          live: {
            roster: {},
            hostControl: {},
            selfState: {},
            hostStatus: 'suspended'
          }
        }
      },
      context: {
        participants: new Map(),
        pendingJoiners: new Map(),
        receivedBooks: [],
        role: 'viewer',
        sharerId: 'host-1',
        me: { userId: 'viewer-1', displayName: 'Sam', authToken: 'jwt' },
        joinUrl: null,
        error: null
      }
    }
    render(<SharingSessionOverlay />)
    expect(screen.getByTestId('host-suspended-banner')).toBeInTheDocument()
  })
})
