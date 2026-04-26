import { describe, it, expect, vi } from 'vitest'
import { render } from '@testing-library/react'
import { PageCurlOverlay } from './PageCurlOverlay'

// Mock the drawPageCurl function so we can verify it's called
vi.mock('./drawPageCurl', () => ({
  drawPageCurl: vi.fn()
}))

describe('PageCurlOverlay', () => {
  it('renders a canvas element', () => {
    const { container } = render(
      <PageCurlOverlay progress={0.5} direction="right" pageColor="#fff" />
    )
    const canvas = container.querySelector('canvas')
    expect(canvas).toBeTruthy()
  })

  it('canvas has pointer-events none', () => {
    const { container } = render(
      <PageCurlOverlay progress={0.5} direction="right" pageColor="#fff" />
    )
    const canvas = container.querySelector('canvas') as HTMLCanvasElement
    expect(canvas.style.pointerEvents).toBe('none')
  })

  it('canvas is positioned absolutely', () => {
    const { container } = render(<PageCurlOverlay progress={0} direction="left" pageColor="#eee" />)
    const canvas = container.querySelector('canvas') as HTMLCanvasElement
    expect(canvas.style.position).toBe('absolute')
  })

  it('canvas covers full width and height of parent', () => {
    const { container } = render(
      <PageCurlOverlay progress={0.3} direction="right" pageColor="#fff" />
    )
    const canvas = container.querySelector('canvas') as HTMLCanvasElement
    expect(canvas.style.width).toBe('100%')
    expect(canvas.style.height).toBe('100%')
  })
})
