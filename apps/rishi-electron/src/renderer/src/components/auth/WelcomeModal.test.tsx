import { describe, it, expect, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { WelcomeModal } from './WelcomeModal'
import { useAuthStore } from '@/stores/authStore'

beforeEach(() => {
  useAuthStore.setState({
    user: null,
    authHydrated: true,
    welcomeSeen: false,
    bannerDismissed: false,
    signInOpen: false
  })
  localStorage.clear()
})

describe('WelcomeModal', () => {
  it('renders when auth is hydrated, no user, and welcome has not been seen', () => {
    render(<WelcomeModal />)
    expect(screen.getByText('Welcome to Rishi')).toBeInTheDocument()
  })

  it('does not render before auth has hydrated', () => {
    useAuthStore.setState({ authHydrated: false })
    const { container } = render(<WelcomeModal />)
    expect(container).toBeEmptyDOMElement()
  })

  it('does not render once the welcome has been dismissed', () => {
    useAuthStore.setState({ welcomeSeen: true })
    const { container } = render(<WelcomeModal />)
    expect(container).toBeEmptyDOMElement()
  })

  it('does not render when a user is signed in', () => {
    useAuthStore.setState({ user: { id: '1', email: 'a@b.com' } })
    const { container } = render(<WelcomeModal />)
    expect(container).toBeEmptyDOMElement()
  })

  it('opens the sign-in flow when "Sign in" is clicked', () => {
    render(<WelcomeModal />)
    fireEvent.click(screen.getByText('Sign in'))
    expect(useAuthStore.getState().signInOpen).toBe(true)
  })

  it('steps aside while the sign-in modal is open so it does not occlude it', () => {
    // Both WelcomeModal and SignInModal use `fixed inset-0 z-50`; if both
    // render at once, WelcomeModal stacks on top (it's mounted after
    // SignInModal in __root.tsx) and the sign-in form is invisible. Hide
    // ourselves while sign-in is open so the user actually sees the form.
    useAuthStore.setState({ signInOpen: true })
    const { container } = render(<WelcomeModal />)
    expect(container).toBeEmptyDOMElement()
  })

  it('dismisses permanently when "Maybe later" is clicked', () => {
    render(<WelcomeModal />)
    fireEvent.click(screen.getByText('Maybe later'))
    expect(useAuthStore.getState().welcomeSeen).toBe(true)
    expect(localStorage.getItem('rishi:welcome-seen')).toBe('1')
  })
})
