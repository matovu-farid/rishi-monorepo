/**
 * State-graph coverage tests for the mobile `connectivityMachine`.
 *
 * Companion to `connectivityMachine.test.ts` — added for consistency with the
 * larger machines in this app so every machine has a graph-derived
 * reachability check. The machine itself is only two states, so this file is
 * intentionally short. Mirror of the electron coverage test at
 * `apps/rishi-electron/src/renderer/src/machines/connectivityMachine.coverage.test.ts`.
 *
 * Uses `getShortestPaths` + `getStateNodes` from `xstate/graph` to:
 *   1. assert every defined state is reachable from the initial state, and
 *   2. exercise the round-trip online -> offline -> online.
 *
 * Note: mobile uses jest (not vitest), and the test file lives under
 * `__tests__/machines/` per `jest.config.js` `roots`.
 */
import { createActor } from 'xstate'
import { getShortestPaths, getStateNodes } from 'xstate/graph'
import {
  connectivityMachine,
  type ConnectivityEvent,
} from '@/lib/machines/connectivityMachine'

const TRAVERSAL_EVENTS: readonly ConnectivityEvent[] = [
  { type: 'ONLINE' },
  { type: 'OFFLINE' },
] as const

describe('connectivityMachine (mobile) state-graph coverage', () => {
  const targets = getStateNodes(connectivityMachine)
    .filter((n) => n.path.length > 0)
    .filter((n) => n.type !== 'history')
    .map((n) => n.path.join('.'))

  it('discovers state nodes from the machine', () => {
    // The machine has exactly two atomic states: online + offline.
    expect(targets.sort()).toEqual(['offline', 'online'])
  })

  for (const stateKey of targets) {
    const paths = getShortestPaths(connectivityMachine, {
      events: TRAVERSAL_EVENTS,
      toState: (snapshot) => snapshot.matches(stateKey as never),
    })

    if (paths.length === 0) {
      it(`reaches ${stateKey}`, () => {
        throw new Error(`no shortest path reaches state "${stateKey}"`)
      })
      continue
    }

    const path = paths[0]
    // v5 `StatePath` has no `description` field — synthesize one from the
    // event sequence so the test name pinpoints the path on failure.
    const description = path.steps.map((s) => s.event.type).join(' -> ') || '<initial>'
    it(`reaches ${stateKey} via ${description}`, () => {
      const actor = createActor(connectivityMachine)
      actor.start()
      for (const step of path.steps) actor.send(step.event)
      expect(actor.getSnapshot().matches(stateKey as never)).toBe(true)
    })
  }
})

describe('connectivityMachine (mobile) round-trip', () => {
  it('online -> offline -> online lands back in online', () => {
    const actor = createActor(connectivityMachine)
    actor.start()
    expect(actor.getSnapshot().value).toBe('online')
    actor.send({ type: 'OFFLINE' })
    expect(actor.getSnapshot().value).toBe('offline')
    actor.send({ type: 'ONLINE' })
    expect(actor.getSnapshot().value).toBe('online')
  })
})
