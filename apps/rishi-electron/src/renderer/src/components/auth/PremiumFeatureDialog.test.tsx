import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { PremiumFeatureDialog } from './PremiumFeatureDialog'
import { PREMIUM_FEATURES } from './features'
import { useAuthStore } from '@/stores/authStore'

beforeEach(() => {
  useAuthStore.setState({ signInOpen: false })
})

describe('PremiumFeatureDialog', () => {
  it('renders dialog with TTS feature content when open', () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="tts" />)

    expect(screen.getByText(PREMIUM_FEATURES.tts.title)).toBeInTheDocument()
    expect(screen.getByText(PREMIUM_FEATURES.tts.description)).toBeInTheDocument()
    for (const bullet of PREMIUM_FEATURES.tts.bullets) {
      expect(screen.getByText(bullet)).toBeInTheDocument()
    }
  })

  it('renders dialog with chat feature content', () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="chat" />)

    expect(screen.getByText(PREMIUM_FEATURES.chat.title)).toBeInTheDocument()
    expect(screen.getByText(PREMIUM_FEATURES.chat.description)).toBeInTheDocument()
  })

  it('does not render dialog when closed', () => {
    render(<PremiumFeatureDialog open={false} onOpenChange={() => {}} feature="tts" />)

    expect(screen.queryByText(PREMIUM_FEATURES.tts.title)).not.toBeInTheDocument()
  })

  it("calls onOpenChange(false) when 'Maybe later' is clicked", () => {
    const onOpenChange = vi.fn()
    render(<PremiumFeatureDialog open={true} onOpenChange={onOpenChange} feature="tts" />)

    fireEvent.click(screen.getByText('Maybe later'))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it('shows sign-in button with correct label', () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="tts" />)

    expect(screen.getByText('Sign in')).toBeInTheDocument()
  })

  it('opens the sign-in flow and closes the dialog when Sign in is clicked', () => {
    const onOpenChange = vi.fn()
    render(<PremiumFeatureDialog open={true} onOpenChange={onOpenChange} feature="tts" />)

    fireEvent.click(screen.getByText('Sign in'))

    expect(onOpenChange).toHaveBeenCalledWith(false)
    expect(useAuthStore.getState().signInOpen).toBe(true)
  })

  it('does not show bullets for ai-generic feature', () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="ai-generic" />)

    expect(screen.getByText(PREMIUM_FEATURES['ai-generic'].title)).toBeInTheDocument()
    expect(screen.queryByRole('listitem')).not.toBeInTheDocument()
  })
})
