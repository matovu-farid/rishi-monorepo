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

describe('useBookSelection — selectAll', () => {
  it('selects exactly the ids of the given list', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.selectAll([{ id: 1 }, { id: 2 }, { id: 3 }]))
    expect(result.current.selectMode).toBe(true)
    expect([...result.current.selectedIds].sort()).toEqual([1, 2, 3])
  })

  it('replaces an existing selection rather than merging', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(99))
    act(() => result.current.selectAll([{ id: 1 }, { id: 2 }]))
    expect([...result.current.selectedIds].sort()).toEqual([1, 2])
  })

  it('handles empty input (no-op selection, mode preserved)', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(5))
    act(() => result.current.selectAll([]))
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.size).toBe(0)
  })
})

describe('useBookSelection — enterSelectMode', () => {
  it('enters Select mode with no id (toolbar Select button)', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.enterSelectMode())
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.size).toBe(0)
  })

  it('enters Select mode pre-seeded with one id (context menu / Cmd+click)', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.enterSelectMode(42))
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.has(42)).toBe(true)
  })
})

describe('useBookSelection — extendTo (Shift+click range)', () => {
  const order = [10, 20, 30, 40, 50]

  it('selects an inclusive forward range from the last-toggled id', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(20)) // anchor
    act(() => result.current.extendTo(40, order))
    expect([...result.current.selectedIds].sort((a, b) => a - b)).toEqual([20, 30, 40])
  })

  it('selects an inclusive reverse range from the last-toggled id', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(40)) // anchor
    act(() => result.current.extendTo(20, order))
    expect([...result.current.selectedIds].sort((a, b) => a - b)).toEqual([20, 30, 40])
  })

  it('falls back to selecting only the target when no anchor exists', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.extendTo(30, order))
    expect([...result.current.selectedIds]).toEqual([30])
  })

  it('preserves existing selection when extending', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(50))
    act(() => result.current.toggle(10)) // newest anchor is 10
    act(() => result.current.extendTo(30, order))
    expect([...result.current.selectedIds].sort((a, b) => a - b)).toEqual([10, 20, 30, 50])
  })
})
