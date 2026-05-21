import { describe, it, expect } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { useBookSelection } from './useBookSelection'

describe('useBookSelection — base state', () => {
  it('starts not in Select mode with an empty selection', () => {
    const { result } = renderHook(() => useBookSelection())
    expect(result.current.selectMode).toBe(false)
    expect(result.current.selectedIds.size).toBe(0)
  })

  it('toggle adds an unselected id and enters Select mode', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(7))
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.has(7)).toBe(true)
  })

  it('toggle removes a selected id', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(7))
    act(() => result.current.toggle(7))
    expect(result.current.selectedIds.has(7)).toBe(false)
  })

  it('clear empties selection but keeps Select mode on', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(1))
    act(() => result.current.toggle(2))
    act(() => result.current.clear())
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.size).toBe(0)
  })

  it('exitSelectMode resets selectMode and selectedIds', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(1))
    act(() => result.current.exitSelectMode())
    expect(result.current.selectMode).toBe(false)
    expect(result.current.selectedIds.size).toBe(0)
  })
})
