import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, fireEvent, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import type { PlayerStoreState } from '@/stores/playerStore'

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

const sendMock = vi.fn()

// We mock @/stores/playerStore with a factory that builds its own Zustand
// store, so both suites work: the Repeat-button suite (initial render) and
// the auto-collapse suite (reactive re-renders via store.setState).
vi.mock('@/stores/playerStore', async () => {
  const { create } = await import('zustand')
  const { subscribeWithSelector } = await import('zustand/middleware')

  type State = { playingState: PlayerStoreState; errors: string[] }

  const store = create<State>()(
    subscribeWithSelector(() => ({
      playingState: 'idle' as PlayerStoreState,
      errors: [] as string[]
    }))
  )

  return {
    usePlayerStore: store
  }
})

vi.mock('@/hooks/usePlayerMachine', () => ({
  usePlayerMachine: () => ({ send: sendMock })
}))

vi.mock('@/hooks/useRequireAuth', () => ({
  useRequireAuth: () => ({
    requireAuth: (_kind: string, fn: () => void) => fn(),
    AuthDialog: null
  })
}))

vi.mock('@/components/tutorial/ContextualHint', () => ({
  ContextualHint: ({ children }: { children: ReactNode }) => <>{children}</>
}))

// Import the component and store AFTER mocks are declared.
import TTSControls from './TTSControls'
import { usePlayerStore } from '@/stores/playerStore'

function expandPill(): void {
  const orb = screen.getByRole('button', { name: /expand tts controls/i })
  fireEvent.click(orb)
}

// ---------------------------------------------------------------------------
// Auto-collapse tests (original suite — needs reactive re-renders)
// ---------------------------------------------------------------------------

describe('TTSControls auto-collapse', () => {
  beforeEach(() => {
    sendMock.mockReset()
    vi.useFakeTimers()
    usePlayerStore.setState({ playingState: 'idle', errors: [] })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('keeps the pill expanded when player is stuck in loading for longer than the dismiss window', () => {
    render(<TTSControls bookId="b1" />)

    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })
    act(() => {
      usePlayerStore.setState({ playingState: 'loading' })
    })

    act(() => {
      vi.advanceTimersByTime(5_000)
    })

    expect(screen.getByLabelText('Play')).toBeInTheDocument()
  })

  it('keeps the pill expanded across playing → pageNavigating → playing', () => {
    render(<TTSControls bookId="b1" />)
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })

    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    act(() => vi.advanceTimersByTime(2_000))
    act(() => usePlayerStore.setState({ playingState: 'pageNavigating' }))
    act(() => vi.advanceTimersByTime(5_000))
    act(() => usePlayerStore.setState({ playingState: 'playing' }))

    expect(screen.getByLabelText('Pause')).toBeInTheDocument()
  })

  it('auto-collapses 4s after entering paused.clean', () => {
    render(<TTSControls bookId="b1" />)
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })

    act(() => usePlayerStore.setState({ playingState: 'paused.clean' }))
    act(() => vi.advanceTimersByTime(4_000))

    expect(screen.queryByLabelText('Pause')).toBeNull()
    expect(screen.queryByLabelText('Play')).toBeNull()
    expect(screen.getByRole('button', { name: /expand tts controls/i })).toBeInTheDocument()
  })

  it('auto-collapses 4s after orb click while idle', () => {
    render(<TTSControls bookId="b1" />)
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })

    act(() => vi.advanceTimersByTime(4_000))

    expect(screen.getByRole('button', { name: /expand tts controls/i })).toBeInTheDocument()
  })
})

// ---------------------------------------------------------------------------
// Repeat button tests (new suite)
// ---------------------------------------------------------------------------

describe('TTSControls — Repeat button', () => {
  beforeEach(() => {
    sendMock.mockReset()
    usePlayerStore.setState({ playingState: 'idle', errors: [] })
  })

  it('renders the Repeat button when playingState is "playing"', () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    expect(screen.getByLabelText('Repeat current paragraph')).toBeInTheDocument()
  })

  it.each<PlayerStoreState>([
    'idle',
    'stopped',
    'loading',
    'paused.clean',
    'paused.stale',
    'waitingForParagraphs',
    'pageNavigating',
    'republishingParagraphs',
    'error'
  ])('does not render the Repeat button when playingState is "%s"', async (state) => {
    act(() => usePlayerStore.setState({ playingState: state }))
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    await waitFor(() => {
      expect(screen.queryByLabelText('Repeat current paragraph')).not.toBeInTheDocument()
    })
  })

  it('clicking Repeat dispatches { type: "REPEAT" } exactly once', () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    const repeat = screen.getByLabelText('Repeat current paragraph')
    fireEvent.click(repeat)
    expect(sendMock).toHaveBeenCalledTimes(1)
    expect(sendMock).toHaveBeenCalledWith({ type: 'REPEAT' })
  })

  it('Repeat sits between Play/Pause and Next in DOM order', () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    const buttons = screen
      .getAllByRole('button')
      .map((b) => b.getAttribute('aria-label'))
      .filter((label): label is string => label !== null)
    const playIdx = buttons.indexOf('Pause') // playing → button label is "Pause"
    const repeatIdx = buttons.indexOf('Repeat current paragraph')
    const nextIdx = buttons.indexOf('Next')
    expect(playIdx).toBeGreaterThanOrEqual(0)
    expect(repeatIdx).toBeGreaterThanOrEqual(0)
    expect(nextIdx).toBeGreaterThanOrEqual(0)
    expect(playIdx).toBeLessThan(repeatIdx)
    expect(repeatIdx).toBeLessThan(nextIdx)
  })
})
