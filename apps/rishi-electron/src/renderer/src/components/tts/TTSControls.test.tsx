import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'
import { useTutorialStore } from '@/stores/tutorialStore'

vi.mock('@/hooks/usePlayerMachine', () => ({
  usePlayerMachine: () => ({ send: vi.fn() })
}))
vi.mock('@/hooks/useRequireAuth', () => ({
  useRequireAuth: () => ({ requireAuth: (_: string, cb: () => void) => cb(), AuthDialog: null })
}))
vi.mock('@/components/tutorial/ContextualHint', () => ({
  ContextualHint: ({ children }: { children: React.ReactNode }) => <>{children}</>
}))

// Import after mocks so the component picks them up.
import TTSControls from './TTSControls'

function setPlayingState(state: Partial<ReturnType<typeof usePlayerStore.getState>>) {
  act(() => {
    usePlayerStore.setState(state)
  })
}

beforeEach(() => {
  vi.useFakeTimers()
  useTutorialStore.setState({ tourActive: false, tourCompleted: true, hintsShown: {} } as never)
  usePlayerStore.setState({ playingState: 'idle' })
})

afterEach(() => {
  vi.useRealTimers()
})

describe('TTSControls auto-collapse', () => {
  it('keeps the pill expanded when player is stuck in loading for longer than the dismiss window', () => {
    render(<TTSControls bookId="b1" />)

    // Expand the pill via the orb.
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })
    setPlayingState({ playingState: 'loading' })

    // Advance well past the 4s dismiss window.
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

    setPlayingState({ playingState: 'playing' })
    act(() => vi.advanceTimersByTime(2_000))
    setPlayingState({ playingState: 'pageNavigating' })
    act(() => vi.advanceTimersByTime(5_000)) // > AUTO_DISMISS_MS
    setPlayingState({ playingState: 'playing' })

    expect(screen.getByLabelText('Pause')).toBeInTheDocument()
  })

  it('auto-collapses 4s after entering paused.clean', () => {
    render(<TTSControls bookId="b1" />)
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })

    setPlayingState({ playingState: 'paused.clean' })
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
