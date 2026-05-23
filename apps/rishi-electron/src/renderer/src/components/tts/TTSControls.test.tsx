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

    // After #232: cold-start (idle → loading) shows spinner immediately, so
    // the play-button accessible name is "Loading" (not "Play"). The intent
    // of this test is that the pill is still expanded — the Play/Pause/Loading
    // button being present at all proves that.
    expect(screen.getByLabelText('Loading')).toBeInTheDocument()
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

  it('stays mounted across the playing → loading → playing paragraph transition', async () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    expect(screen.getByLabelText('Repeat current paragraph')).toBeInTheDocument()

    // Simulate the brief inter-paragraph load: state dips to 'loading'.
    act(() => usePlayerStore.setState({ playingState: 'loading' }))
    expect(screen.getByLabelText('Repeat current paragraph')).toBeInTheDocument()

    // And then snaps back to 'playing' for the next paragraph.
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    expect(screen.getByLabelText('Repeat current paragraph')).toBeInTheDocument()
  })

  it('unmounts immediately when the user pauses (no loading bridge)', async () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    expect(screen.getByLabelText('Repeat current paragraph')).toBeInTheDocument()

    act(() => usePlayerStore.setState({ playingState: 'paused.clean' }))
    await waitFor(() => {
      expect(screen.queryByLabelText('Repeat current paragraph')).not.toBeInTheDocument()
    })
  })
})

// ---------------------------------------------------------------------------
// Play-button spinner debounce (#232)
//
// The TTS player dips through `loading` at every paragraph boundary even when
// the next paragraph's audio is already cached. Showing the spinner during
// these sub-200ms dips makes the play-button icon flicker. The fix is an
// asymmetric debounce: delay the spinner ~200ms when arriving from an active
// playback state, hide immediately, and never delay on cold-start /
// pause→resume.
// ---------------------------------------------------------------------------

describe('TTSControls — play spinner debounce (#232)', () => {
  beforeEach(() => {
    sendMock.mockReset()
    vi.useFakeTimers()
    usePlayerStore.setState({ playingState: 'idle', errors: [] })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('does not show the spinner during a cached playing → loading → playing transition', () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    const { container } = render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })

    // Cached-paragraph dip: ~50ms in 'loading' before snapping back.
    act(() => usePlayerStore.setState({ playingState: 'loading' }))
    expect(screen.queryByLabelText('Loading')).toBeNull()
    expect(container.querySelector('.animate-spin')).toBeNull()

    act(() => vi.advanceTimersByTime(50))
    expect(screen.queryByLabelText('Loading')).toBeNull()
    expect(container.querySelector('.animate-spin')).toBeNull()

    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    expect(screen.queryByLabelText('Loading')).toBeNull()
    expect(container.querySelector('.animate-spin')).toBeNull()

    // Pause icon should remain steady throughout.
    expect(screen.getByLabelText('Pause')).toBeInTheDocument()
  })

  it('shows the spinner after the debounce window when load genuinely stalls', () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    const { container } = render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })

    act(() => usePlayerStore.setState({ playingState: 'loading' }))
    // Before debounce fires: still steady.
    act(() => vi.advanceTimersByTime(150))
    expect(container.querySelector('.animate-spin')).toBeNull()

    // After debounce fires: spinner appears.
    act(() => vi.advanceTimersByTime(150))
    expect(container.querySelector('.animate-spin')).not.toBeNull()
    expect(screen.getByLabelText('Loading')).toBeInTheDocument()
  })

  it('shows the spinner immediately on cold-start (idle → loading, no debounce)', () => {
    const { container } = render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })

    act(() => usePlayerStore.setState({ playingState: 'loading' }))
    // No timer advance — spinner should be visible right away because the
    // predecessor (`idle`) is NOT an active-playback state.
    expect(container.querySelector('.animate-spin')).not.toBeNull()
    expect(screen.getByLabelText('Loading')).toBeInTheDocument()
  })

  it('shows the spinner immediately on pause → resume (paused.clean → loading, no debounce)', () => {
    act(() => usePlayerStore.setState({ playingState: 'paused.clean' }))
    const { container } = render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })

    act(() => usePlayerStore.setState({ playingState: 'loading' }))
    // Predecessor `paused.clean` is not active playback — spinner is immediate.
    expect(container.querySelector('.animate-spin')).not.toBeNull()
    expect(screen.getByLabelText('Loading')).toBeInTheDocument()
  })

  it('hides the spinner immediately when loading ends after the debounce fired', () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    const { container } = render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })

    act(() => usePlayerStore.setState({ playingState: 'loading' }))
    act(() => vi.advanceTimersByTime(300))
    expect(container.querySelector('.animate-spin')).not.toBeNull()

    // When loading completes, hide is immediate — no delay-hide.
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    expect(container.querySelector('.animate-spin')).toBeNull()
  })

  it('keeps Prev/Next disabled while raw playingState === "loading" (independent of spinner debounce)', () => {
    act(() => usePlayerStore.setState({ playingState: 'playing' }))
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })

    act(() => usePlayerStore.setState({ playingState: 'loading' }))
    // Even though the spinner is suppressed, the Prev/Next gates must still
    // honour the raw loading state (real races, e.g. mid-load nav).
    expect(screen.getByLabelText('Previous')).toBeDisabled()
    expect(screen.getByLabelText('Next')).toBeDisabled()
  })
})
