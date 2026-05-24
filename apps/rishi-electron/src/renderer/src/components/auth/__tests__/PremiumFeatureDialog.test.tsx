/**
 * Phase 1 — PremiumFeatureDialog (electron) — shared FEATURE_COPY contract.
 *
 * This test pins the electron dialog to the shared copy source. After the
 * architect's rewire of `features.ts` (the local shim now sources
 * description from `FEATURE_COPY.body`), the electron dialog renders the
 * exact same prompt strings that mobile's `PremiumFeatureSheet` renders.
 *
 * The dialog component itself does not change — only its copy source.
 * Bullets are kept as an electron-only field on the local shim's
 * `PremiumFeatureConfig`.
 *
 * Patterns mirror the existing `WelcomeModal.test.tsx` / co-located
 * `PremiumFeatureDialog.test.tsx` setup so this file slots into the
 * established vitest + @testing-library/react flow.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { PremiumFeatureDialog } from '../PremiumFeatureDialog'
import { PREMIUM_FEATURES } from '../features'
import { FEATURE_COPY } from '@rishi/shared/auth-gating'
import { useAuthStore } from '@/stores/authStore'

beforeEach(() => {
  useAuthStore.setState({ signInOpen: false })
})

describe('PremiumFeatureDialog (consumes shared FEATURE_COPY)', () => {
  it("renders the shared FEATURE_COPY title for 'tts'", () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="tts" />)
    expect(screen.getByText('Sign in to listen')).toBeInTheDocument()
    expect(screen.getByText(FEATURE_COPY.tts.title)).toBeInTheDocument()
  })

  it("renders the shared FEATURE_COPY body as the dialog description for 'ai-chat'", () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="ai-chat" />)
    expect(screen.getByText(FEATURE_COPY['ai-chat'].body)).toBeInTheDocument()
  })

  it("renders bullets for 'tts' (electron-only feature list)", () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="tts" />)
    // The shim provides 3 bullets for tts — bullets are an electron-only
    // augmentation of the shared copy.
    const bullets = PREMIUM_FEATURES.tts.bullets
    expect(bullets.length).toBe(3)
    for (const b of bullets) {
      expect(screen.getByText(b)).toBeInTheDocument()
    }
  })

  it("calls onOpenChange(false) when 'Maybe later' is clicked", () => {
    const onOpenChange = vi.fn()
    render(<PremiumFeatureDialog open={true} onOpenChange={onOpenChange} feature="tts" />)
    fireEvent.click(screen.getByText('Maybe later'))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it("calls openSignIn() on the auth store when 'Sign in' is clicked", () => {
    render(<PremiumFeatureDialog open={true} onOpenChange={() => {}} feature="tts" />)
    fireEvent.click(screen.getByText('Sign in'))
    expect(useAuthStore.getState().signInOpen).toBe(true)
  })
})
