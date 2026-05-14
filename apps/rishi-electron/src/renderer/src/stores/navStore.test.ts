import { describe, it, expect, beforeEach, vi } from 'vitest'
import { useNavStore } from './navStore'

describe('navStore', () => {
  beforeEach(() => {
    useNavStore.setState({
      navState: 'idle',
      send: null
    })
  })

  it('should start in idle state', () => {
    expect(useNavStore.getState().navState).toBe('idle')
  })

  it('should have null send function initially', () => {
    expect(useNavStore.getState().send).toBeNull()
  })

  it('should set nav state', () => {
    useNavStore.getState().setNavState('navigating')
    expect(useNavStore.getState().navState).toBe('navigating')
  })

  it('should set send function', () => {
    const mockSend = vi.fn()
    useNavStore.getState().setSend(mockSend)
    expect(useNavStore.getState().send).toBe(mockSend)
  })

  it('should allow clearing send function', () => {
    const mockSend = vi.fn()
    useNavStore.getState().setSend(mockSend)
    useNavStore.getState().setSend(null)
    expect(useNavStore.getState().send).toBeNull()
  })

  it('should allow setting nav state to various values', () => {
    const states = ['idle', 'navigating', 'loading', 'error', 'ready']
    for (const state of states) {
      useNavStore.getState().setNavState(state as any)
      expect(useNavStore.getState().navState).toBe(state)
    }
  })

  it('should replace send function when set again', () => {
    const send1 = vi.fn()
    const send2 = vi.fn()
    useNavStore.getState().setSend(send1)
    expect(useNavStore.getState().send).toBe(send1)
    useNavStore.getState().setSend(send2)
    expect(useNavStore.getState().send).toBe(send2)
    expect(useNavStore.getState().send).not.toBe(send1)
  })

  it('should call the send function with events when invoked', () => {
    const mockSend = vi.fn()
    useNavStore.getState().setSend(mockSend)

    const sendFn = useNavStore.getState().send
    expect(sendFn).not.toBeNull()
    const event = { type: 'DISPLAY', location: 'chapter-5' } as const
    sendFn!(event)
    expect(mockSend).toHaveBeenCalledWith(event)
  })

  it('should not throw when setting nav state rapidly', () => {
    for (let i = 0; i < 100; i++) {
      useNavStore.getState().setNavState(i % 2 === 0 ? 'idle' : ('navigating' as any))
    }
    expect(useNavStore.getState().navState).toBeDefined()
  })
})
