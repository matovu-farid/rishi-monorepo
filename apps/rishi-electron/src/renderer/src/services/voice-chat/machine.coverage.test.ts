/**
 * State-graph coverage tests for `voiceChatMachine`.
 *
 * Mirrors the structure of `playerMachine.coverage.test.ts`. The hand-rolled
 * `actor.send(...)` tests in `machine.test.ts` already cover the well-known
 * transitions; this file complements them by:
 *
 *   - asserting every defined state node is reachable from the initial state
 *   - generating shortest paths to `error` and `offline` and proving each has
 *     a clean recovery back into the working set (`idle` / `connecting`)
 *
 * The machine has no `invoke`/`after`, so `createTestModel` would technically
 * work — but we stick with `getShortestPaths` + manual walk to match the
 * playerMachine template the repo has standardized on.
 */
import { describe, it, expect } from 'vitest'
import { createActor } from 'xstate'
import { getShortestPaths, getStateNodes } from 'xstate/graph'
import { voiceChatMachine, type VoiceChatMachineEvent } from './machine'

// ---------- helpers --------------------------------------------------------

/**
 * Events fed into the graph traversal. Covers every event the machine
 * actually handles — keeping the alphabet tight prevents path explosion.
 */
const TRAVERSAL_EVENTS: readonly VoiceChatMachineEvent[] = [
  { type: 'CONNECT_STARTED' },
  { type: 'CONNECT_SUCCEEDED' },
  { type: 'CONNECT_FAILED', reason: 'connect_failed', message: 'boom' },
  { type: 'DEACTIVATE' },
  { type: 'DISPOSE' },
  { type: 'OFFLINE' },
  { type: 'ONLINE' },
  { type: 'SESSION_ERROR', reason: 'session_error', message: 'boom' },
  { type: 'DISMISS_ERROR' }
] as const

/**
 * Project the snapshot into a compact key. We drop the `error` object so the
 * graph treats `{error: null}` and `{error: {...}}` as the same node for
 * traversal purposes — the state value is what determines reachability.
 */
function serializeState(snapshot: ReturnType<typeof voiceChatMachine.transition>): string {
  return JSON.stringify({
    value: snapshot.value,
    hasError: snapshot.context.error !== null
  })
}

// ---------- 1. Reachability of every defined state -------------------------

describe('voiceChatMachine state-graph coverage', () => {
  // v5 API note: this machine has no invocations, so `createTestModel` would
  // work, but we deliberately use the same `getShortestPaths` shape as
  // `playerMachine.coverage.test.ts` for consistency across the repo.
  const targets = getStateNodes(voiceChatMachine)
    .filter((n) => n.path.length > 0)
    .filter((n) => n.type !== 'history')
    .map((n) => n.path.join('.'))

  it('discovers state nodes from the machine', () => {
    expect(targets.length).toBeGreaterThan(0)
    // Sanity: the six documented top-level states should all be discovered.
    expect(targets).toEqual(
      expect.arrayContaining(['idle', 'connecting', 'active', 'paused', 'offline', 'error'])
    )
  })

  for (const stateKey of targets) {
    const paths = getShortestPaths(voiceChatMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches(stateKey as never)
    })

    if (paths.length === 0) {
      it(`reaches ${stateKey}`, () => {
        throw new Error(`no shortest path reaches state "${stateKey}"`)
      })
      continue
    }

    const path = paths[0]
    const description = path.steps.map((s) => s.event.type).join(' -> ') || '<initial>'
    it(`reaches ${stateKey} via ${description}`, () => {
      const actor = createActor(voiceChatMachine)
      actor.start()
      for (const step of path.steps) {
        actor.send(step.event)
      }
      const snap = actor.getSnapshot()
      expect(
        snap.matches(stateKey as never),
        `walked shortest path to "${stateKey}" but actor landed in ${JSON.stringify(snap.value)}`
      ).toBe(true)
    })
  }
})

// ---------- 2. Recovery paths from terminal-ish states ---------------------

describe('voiceChatMachine targeted coverage — error recovery', () => {
  it('every shortest path to error can recover via DISMISS_ERROR → idle', () => {
    const paths = getShortestPaths(voiceChatMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches('error')
    })
    expect(paths.length).toBeGreaterThan(0)

    for (const path of paths) {
      const actor = createActor(voiceChatMachine)
      actor.start()
      for (const step of path.steps) actor.send(step.event)
      expect(actor.getSnapshot().matches('error')).toBe(true)
      // storeError should have populated context.error
      expect(actor.getSnapshot().context.error).not.toBeNull()

      actor.send({ type: 'DISMISS_ERROR' })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('idle')
      expect(snap.context.error).toBeNull()
    }
  })

  it('error → CONNECT_STARTED retries via connecting (without clearing error mid-flight)', () => {
    const paths = getShortestPaths(voiceChatMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches('error')
    })
    expect(paths.length).toBeGreaterThan(0)

    const actor = createActor(voiceChatMachine)
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    actor.send({ type: 'CONNECT_STARTED' })
    expect(actor.getSnapshot().value).toBe('connecting')

    // CONNECT_SUCCEEDED clears the error on entry to active.
    actor.send({ type: 'CONNECT_SUCCEEDED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('active')
    expect(snap.context.error).toBeNull()
  })
})

describe('voiceChatMachine targeted coverage — offline recovery', () => {
  it('every shortest path to offline can recover via ONLINE → idle', () => {
    const paths = getShortestPaths(voiceChatMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches('offline')
    })
    expect(paths.length).toBeGreaterThan(0)

    for (const path of paths) {
      const actor = createActor(voiceChatMachine)
      actor.start()
      for (const step of path.steps) actor.send(step.event)
      expect(actor.getSnapshot().matches('offline')).toBe(true)

      actor.send({ type: 'ONLINE' })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('idle')
      expect(snap.context.error).toBeNull()
    }
  })

  it('OFFLINE is honored from every reachable state (global handler)', () => {
    // Walk to each reachable state, then send OFFLINE; we should always land
    // in `offline`. This is the global `on.OFFLINE` contract.
    const targets = ['idle', 'connecting', 'active', 'paused', 'error'] as const
    for (const stateKey of targets) {
      const paths = getShortestPaths(voiceChatMachine, {
        events: TRAVERSAL_EVENTS,
        serializeState,
        toState: (snapshot) => snapshot.matches(stateKey)
      })
      expect(paths.length, `no path to ${stateKey}`).toBeGreaterThan(0)

      const actor = createActor(voiceChatMachine)
      actor.start()
      for (const step of paths[0].steps) actor.send(step.event)
      actor.send({ type: 'OFFLINE' })
      expect(actor.getSnapshot().value, `OFFLINE from ${stateKey} did not land in offline`).toBe(
        'offline'
      )
    }
  })
})
