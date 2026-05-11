import { describe, it, expect, vi } from 'vitest'
import { createEmitter } from './emitter'

describe('createEmitter', () => {
  it('delivers emitted values to a subscribed listener', () => {
    const e = createEmitter<{ value: number }>()
    const listener = vi.fn()
    e.on(listener)

    e.emit({ value: 42 })

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith({ value: 42 })
  })

  it('fans an emit out to every subscriber', () => {
    const e = createEmitter<string>()
    const a = vi.fn()
    const b = vi.fn()
    e.on(a)
    e.on(b)

    e.emit('hello')

    expect(a).toHaveBeenCalledWith('hello')
    expect(b).toHaveBeenCalledWith('hello')
  })

  it('returns an unsubscribe function that removes the listener', () => {
    const e = createEmitter<number>()
    const listener = vi.fn()
    const unsubscribe = e.on(listener)

    e.emit(1)
    unsubscribe()
    e.emit(2)

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith(1)
  })
})
