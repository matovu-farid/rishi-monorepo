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

function setPlayingState(state: Parameters<typeof usePlayerStore.setState>[0]) {
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
})
