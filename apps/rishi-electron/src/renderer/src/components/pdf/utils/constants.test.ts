import { describe, it, expect } from 'vitest'
import { PAGE_HEIGHT, PAGE_GAP } from './constants'

describe('PDF constants', () => {
  it('exports PAGE_HEIGHT as 1540', () => {
    expect(PAGE_HEIGHT).toBe(1540)
  })

  it('exports PAGE_GAP as 16', () => {
    expect(PAGE_GAP).toBe(16)
  })

  it('PAGE_HEIGHT is a positive number', () => {
    expect(PAGE_HEIGHT).toBeGreaterThan(0)
  })

  it('PAGE_GAP is a positive number', () => {
    expect(PAGE_GAP).toBeGreaterThan(0)
  })
})
