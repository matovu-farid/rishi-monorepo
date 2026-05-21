import { describe, it, expectTypeOf } from 'vitest'
import type { ConnectivityService, ConnectivityListener, ConnectivitySource } from './types'
import type { ConnectivityPort } from '../sync/types'

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

  it('the navigator + window split satisfies ConnectivitySource', () => {
    // Compile-time assertion — fails build if the typed surface drifts.
    // `onLine` lives on `navigator`, while `online`/`offline` events fire
    // on `window`. Production composes them into a single source object
    // (see electron's `services/index.ts#getConnectivityService`). The
    // test runs in a non-DOM env (worker tsc includes this file), so we
    // build a structural fake rather than referencing the globals.
    const fake = {
      onLine: true,
      addEventListener: (_t: 'online' | 'offline', _l: () => void): void => undefined,
      removeEventListener: (_t: 'online' | 'offline', _l: () => void): void => undefined
    }
    const _source: ConnectivitySource = fake
    void _source
  })
})
