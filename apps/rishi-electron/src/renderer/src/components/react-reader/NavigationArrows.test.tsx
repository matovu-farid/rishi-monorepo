import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { NavigationArrows } from './NavigationArrows'

describe('NavigationArrows', () => {
  it('renders both prev and next buttons by default', () => {
    render(<NavigationArrows onPrev={vi.fn()} onNext={vi.fn()} />)
    expect(screen.getByLabelText('Previous page')).toBeInTheDocument()
    expect(screen.getByLabelText('Next page')).toBeInTheDocument()
  })

  it('hides the prev button when hidePrev is true', () => {
    render(<NavigationArrows onPrev={vi.fn()} onNext={vi.fn()} hidePrev />)
    expect(screen.queryByLabelText('Previous page')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Next page')).toBeInTheDocument()
  })

  it('hides the next button when hideNext is true', () => {
    render(<NavigationArrows onPrev={vi.fn()} onNext={vi.fn()} hideNext />)
    expect(screen.getByLabelText('Previous page')).toBeInTheDocument()
    expect(screen.queryByLabelText('Next page')).not.toBeInTheDocument()
  })

  it('hides both buttons when hidePrev and hideNext are true', () => {
    render(<NavigationArrows onPrev={vi.fn()} onNext={vi.fn()} hidePrev hideNext />)
    expect(screen.queryByLabelText('Previous page')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Next page')).not.toBeInTheDocument()
  })

  it('calls onPrev when the previous button is clicked', () => {
    const onPrev = vi.fn()
    render(<NavigationArrows onPrev={onPrev} onNext={vi.fn()} />)
    fireEvent.click(screen.getByLabelText('Previous page'))
    expect(onPrev).toHaveBeenCalledOnce()
  })

  it('calls onNext when the next button is clicked', () => {
    const onNext = vi.fn()
    render(<NavigationArrows onPrev={vi.fn()} onNext={onNext} />)
    fireEvent.click(screen.getByLabelText('Next page'))
    expect(onNext).toHaveBeenCalledOnce()
  })

  it('stops pointer-down propagation on buttons', () => {
    render(<NavigationArrows onPrev={vi.fn()} onNext={vi.fn()} />)
    const nextBtn = screen.getByLabelText('Next page')
    const event = new MouseEvent('pointerdown', { bubbles: true })
    const stopProp = vi.spyOn(event, 'stopPropagation')
    nextBtn.dispatchEvent(event)
    expect(stopProp).toHaveBeenCalled()
  })
})
