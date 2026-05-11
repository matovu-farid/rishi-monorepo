import { describe, it, expect, vi } from 'vitest'
import { createEmitter } from './emitter'

describe('createEmitter', () => {
  it('fans an emission out to every subscriber', () => {
    const e = createEmitter<number>()
    const a = vi.fn()
    const b = vi.fn()
    e.on(a)
    e.on(b)

    e.emit(7)

    expect(a).toHaveBeenCalledWith(7)
    expect(b).toHaveBeenCalledWith(7)
  })

  it('on() returns an unsubscribe that stops further deliveries', () => {
    const e = createEmitter<string>()
    const spy = vi.fn()
    const off = e.on(spy)

    e.emit('one')
    off()
    e.emit('two')

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith('one')
  })

  it('emit with no subscribers is a no-op', () => {
    const e = createEmitter<boolean>()
    expect(() => e.emit(true)).not.toThrow()
  })
})
