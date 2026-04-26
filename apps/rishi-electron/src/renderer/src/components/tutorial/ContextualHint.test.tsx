import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ContextualHint } from './ContextualHint'
import { useTutorialStore } from '@/stores/tutorialStore'

// Mock framer-motion
vi.mock('framer-motion', () => ({
  motion: {
    div: ({
      children,
      className
    }: React.HTMLAttributes<HTMLDivElement> & Record<string, unknown>) => (
      <div className={className} data-testid="hint-popover">
        {children}
      </div>
    )
  },
  AnimatePresence: ({ children }: { children: React.ReactNode }) => <>{children}</>
}))

describe('ContextualHint', () => {
  beforeEach(() => {
    localStorage.clear()
    useTutorialStore.setState({
      tourActive: false,
      tourCompleted: true,
      hintsShown: {}
    })
  })

  it('renders children always', () => {
    render(
      <ContextualHint id="test" title="Hint Title" description="Hint description">
        <button>Target Button</button>
      </ContextualHint>
    )

    expect(screen.getByText('Target Button')).toBeInTheDocument()
  })

  it('shows pulsing dot when tour is completed and hint is unseen', () => {
    render(
      <ContextualHint id="test" title="Hint Title" description="Hint description">
        <button>Target</button>
      </ContextualHint>
    )

    expect(screen.getByLabelText('Hint: Hint Title')).toBeInTheDocument()
  })

  it('does not show pulsing dot when tour is active', () => {
    useTutorialStore.setState({ tourActive: true, tourCompleted: false })

    render(
      <ContextualHint id="test" title="Hint Title" description="Hint description">
        <button>Target</button>
      </ContextualHint>
    )

    expect(screen.queryByLabelText('Hint: Hint Title')).not.toBeInTheDocument()
  })

  it('does not show pulsing dot when tour has not been completed', () => {
    useTutorialStore.setState({ tourActive: false, tourCompleted: false })

    render(
      <ContextualHint id="test" title="Hint Title" description="Hint description">
        <button>Target</button>
      </ContextualHint>
    )

    expect(screen.queryByLabelText('Hint: Hint Title')).not.toBeInTheDocument()
  })

  it('does not show pulsing dot when hint has been dismissed', () => {
    useTutorialStore.setState({ hintsShown: { test: true } })

    render(
      <ContextualHint id="test" title="Hint Title" description="Hint description">
        <button>Target</button>
      </ContextualHint>
    )

    expect(screen.queryByLabelText('Hint: Hint Title')).not.toBeInTheDocument()
  })

  it('shows popover when pulsing dot is clicked', () => {
    render(
      <ContextualHint id="test" title="Hint Title" description="Hint description">
        <button>Target</button>
      </ContextualHint>
    )

    fireEvent.click(screen.getByLabelText('Hint: Hint Title'))
    expect(screen.getByText('Hint Title')).toBeInTheDocument()
    expect(screen.getByText('Hint description')).toBeInTheDocument()
  })

  it("dismisses hint when 'Got it' is clicked", () => {
    render(
      <ContextualHint id="test" title="Hint Title" description="Hint description">
        <button>Target</button>
      </ContextualHint>
    )

    // Open the popover
    fireEvent.click(screen.getByLabelText('Hint: Hint Title'))
    // Click "Got it"
    fireEvent.click(screen.getByText('Got it'))

    // Hint should be dismissed in the store
    expect(useTutorialStore.getState().hintsShown['test']).toBe(true)
  })
})
