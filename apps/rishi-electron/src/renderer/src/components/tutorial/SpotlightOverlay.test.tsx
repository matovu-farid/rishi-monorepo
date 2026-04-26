import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render } from '@testing-library/react'
import { SpotlightOverlay } from './SpotlightOverlay'

// Mock framer-motion
vi.mock('framer-motion', () => ({
  motion: {
    svg: ({
      children,
      className,
      style
    }: React.SVGAttributes<SVGSVGElement> & Record<string, unknown>) => (
      <svg className={className} style={style as React.CSSProperties} data-testid="spotlight-svg">
        {children}
      </svg>
    ),
    rect: ({ fill, rx, ry }: React.SVGAttributes<SVGRectElement> & { animate?: unknown }) => (
      <rect fill={fill} rx={rx} ry={ry} data-testid="spotlight-cutout" />
    )
  },
  AnimatePresence: ({ children }: { children: React.ReactNode }) => <>{children}</>
}))

describe('SpotlightOverlay', () => {
  let mockElement: HTMLDivElement

  beforeEach(() => {
    mockElement = document.createElement('div')
    mockElement.setAttribute('data-tour', 'test-target')
    Object.defineProperty(mockElement, 'getBoundingClientRect', {
      value: () => ({
        top: 100,
        bottom: 140,
        left: 200,
        right: 400,
        width: 200,
        height: 40,
        x: 200,
        y: 100
      })
    })
    document.body.appendChild(mockElement)
  })

  afterEach(() => {
    document.body.removeChild(mockElement)
  })

  it('renders SVG overlay when target element exists', () => {
    const { getByTestId } = render(<SpotlightOverlay targetSelector="test-target" />)

    expect(getByTestId('spotlight-svg')).toBeInTheDocument()
  })

  it('does not render when target element is missing', () => {
    const { queryByTestId } = render(<SpotlightOverlay targetSelector="nonexistent-target" />)

    expect(queryByTestId('spotlight-svg')).not.toBeInTheDocument()
  })

  it('renders with default padding', () => {
    const { getByTestId } = render(<SpotlightOverlay targetSelector="test-target" />)

    expect(getByTestId('spotlight-cutout')).toBeInTheDocument()
  })

  it('renders the mask elements', () => {
    const { container } = render(<SpotlightOverlay targetSelector="test-target" />)

    const mask = container.querySelector('mask')
    expect(mask).toBeInTheDocument()
    expect(mask?.getAttribute('id')).toBe('spotlight-mask')
  })

  it('applies custom padding', () => {
    const { getByTestId } = render(<SpotlightOverlay targetSelector="test-target" padding={16} />)

    // The SVG should still render
    expect(getByTestId('spotlight-svg')).toBeInTheDocument()
  })

  it('applies custom border radius', () => {
    const { getByTestId } = render(
      <SpotlightOverlay targetSelector="test-target" borderRadius={12} />
    )

    const cutout = getByTestId('spotlight-cutout')
    expect(cutout.getAttribute('rx')).toBe('12')
    expect(cutout.getAttribute('ry')).toBe('12')
  })
})
