import { describe, it, expect, vi, beforeEach } from 'vitest'
import { getCurrrentPageNumber } from './getCurrentPageNumbers'

describe('getCurrrentPageNumber', () => {
  beforeEach(() => {
    // Clean up any existing page elements
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild)
    }
  })

  it('returns 1 when no canvas elements exist', () => {
    const result = getCurrrentPageNumber(window)
    expect(result).toBe(1)
  })

  it('returns the page number of the only visible canvas', () => {
    // Create a page element with a canvas
    const pageDiv = document.createElement('div')
    pageDiv.setAttribute('data-page-number', '3')
    const canvas = document.createElement('canvas')
    pageDiv.appendChild(canvas)
    document.body.appendChild(pageDiv)

    // Mock getBoundingClientRect so the canvas is visible
    vi.spyOn(canvas, 'getBoundingClientRect').mockReturnValue({
      top: 100,
      bottom: 300,
      left: 0,
      right: 800,
      width: 800,
      height: 200,
      x: 0,
      y: 100,
      toJSON: () => ({})
    })

    // Mock window dimensions
    Object.defineProperty(window, 'innerHeight', { value: 768, writable: true })
    Object.defineProperty(window, 'innerWidth', { value: 1024, writable: true })

    const result = getCurrrentPageNumber(window)
    expect(result).toBe(3)
  })

  it('returns the page with the largest visible area when multiple pages are visible', () => {
    // Page 1: small visible area
    const page1 = document.createElement('div')
    page1.setAttribute('data-page-number', '1')
    const canvas1 = document.createElement('canvas')
    page1.appendChild(canvas1)
    document.body.appendChild(page1)

    // Page 2: large visible area
    const page2 = document.createElement('div')
    page2.setAttribute('data-page-number', '2')
    const canvas2 = document.createElement('canvas')
    page2.appendChild(canvas2)
    document.body.appendChild(page2)

    // Mock inner dimensions
    Object.defineProperty(window, 'innerHeight', { value: 768, writable: true })
    Object.defineProperty(window, 'innerWidth', { value: 1024, writable: true })

    // Page 1: barely visible (only 50px showing)
    vi.spyOn(canvas1, 'getBoundingClientRect').mockReturnValue({
      top: -450,
      bottom: 50,
      left: 0,
      right: 800,
      width: 800,
      height: 500,
      x: 0,
      y: -450,
      toJSON: () => ({})
    })

    // Page 2: mostly visible
    vi.spyOn(canvas2, 'getBoundingClientRect').mockReturnValue({
      top: 50,
      bottom: 550,
      left: 0,
      right: 800,
      width: 800,
      height: 500,
      x: 0,
      y: 50,
      toJSON: () => ({})
    })

    const result = getCurrrentPageNumber(window)
    expect(result).toBe(2)
  })
})
