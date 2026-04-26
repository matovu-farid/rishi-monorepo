import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { SwipeWrapper } from './SwipeWrapper'

// Mock @use-gesture/react to avoid DOM binding issues in happy-dom
vi.mock('@use-gesture/react', () => ({
  useWheel: vi.fn()
}))

describe('SwipeWrapper', () => {
  it('renders children', () => {
    render(
      <SwipeWrapper swipeProps={{}}>
        <span data-testid="child">Hello</span>
      </SwipeWrapper>
    )
    expect(screen.getByTestId('child')).toBeInTheDocument()
    expect(screen.getByTestId('child').textContent).toBe('Hello')
  })

  it('renders a wrapper div with full height', () => {
    const { container } = render(
      <SwipeWrapper swipeProps={{}}>
        <div>Content</div>
      </SwipeWrapper>
    )
    const wrapper = container.firstElementChild as HTMLElement
    expect(wrapper.style.height).toBe('100%')
  })

  it('accepts swipeLeft and swipeRight callbacks without crashing', () => {
    const onSwipeLeft = vi.fn()
    const onSwipeRight = vi.fn()
    const { container } = render(
      <SwipeWrapper swipeProps={{}} onSwipeLeft={onSwipeLeft} onSwipeRight={onSwipeRight}>
        <div>Content</div>
      </SwipeWrapper>
    )
    // The component should mount without errors
    expect(container.firstElementChild).toBeTruthy()
  })
})
