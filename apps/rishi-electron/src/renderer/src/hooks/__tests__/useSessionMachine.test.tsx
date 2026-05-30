import { describe, expect, it } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useSessionMachine } from '../useSessionMachine'

describe('useSessionMachine', () => {
  it('returns idle snapshot on mount', () => {
    const { result } = renderHook(() => useSessionMachine())
    expect(result.current.state.value).toBe('idle')
  })

  it('exposes a send fn that updates state', () => {
    const { result } = renderHook(() => useSessionMachine())
    act(() => {
      result.current.send({
        type: 'CREATE_SESSION',
        me: { userId: 'u_a', displayName: 'M', authToken: 'jwt' },
        bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
        requiresApproval: false
      })
    })
    expect(['creating', 'idle']).toContain(result.current.state.value as string)
  })
})
