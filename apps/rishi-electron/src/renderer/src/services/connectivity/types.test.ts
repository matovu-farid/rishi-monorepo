import { describe, it, expectTypeOf } from 'vitest'
import type { ConnectivityService, ConnectivityListener, ConnectivitySource } from './types'
import type { ConnectivityPort } from '@/services/sync/types'

describe('ConnectivityService type compatibility', () => {
  it('is assignable to Sync ConnectivityPort (structural overlap on isOnline + subscribe)', () => {
    expectTypeOf<ConnectivityService>().toMatchTypeOf<ConnectivityPort>()
  })

  it('isOnline returns boolean', () => {
    expectTypeOf<ConnectivityService['isOnline']>().returns.toEqualTypeOf<boolean>()
  })

  it('subscribe takes (online: boolean) => void and returns an unsubscribe fn', () => {
    expectTypeOf<ConnectivityService['subscribe']>().parameters.toEqualTypeOf<
      [ConnectivityListener]
    >()
    expectTypeOf<ConnectivityService['subscribe']>().returns.toEqualTypeOf<() => void>()
  })

  it('ConnectivitySource matches the navigator/window event surface', () => {
    expectTypeOf<ConnectivitySource['onLine']>().toEqualTypeOf<boolean>()
    expectTypeOf<ConnectivitySource['addEventListener']>().parameters.toEqualTypeOf<
      ['online' | 'offline', () => void]
    >()
  })

  it('window satisfies ConnectivitySource', () => {
    // Compile-time assertion — fails build if window's typed surface drifts.
    const _w: ConnectivitySource = window
    void _w
  })
})
