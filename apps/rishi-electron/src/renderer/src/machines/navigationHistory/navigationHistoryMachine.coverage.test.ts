/**
 * State-graph coverage tests for `navigationHistoryMachine`.
 *
 * The hand-rolled `actor.send(...)` tests in navigationHistoryMachine.test.ts
 * exercise each region (stack / engagement / pill) in isolation but don't
 * cross-product them — so a regression in how one region's transitions
 * interact with another (e.g. JUMP_REQUESTED firing while engagement is
 * `paused`) can slip through.
 *
 * This file uses the `xstate/graph` API (`getShortestPaths` / `getStateNodes`)
 * to (a) prove every state node in the machine is reachable from the initial
 * state via *some* event sequence, and (b) walk a few targeted paths that
 * cross region boundaries (engagement → resumeMap → cross-region emit).
 *
 * v5 API note: `createTestModel(machine)` + `path.test({states, events})` is
 * the canonical Stately graph-coverage pattern, but `createTestModel` throws
 * "After events on test machines are not supported" because this machine has
 * an `after: { DWELL_TIMER }` transition in `engagement.dwelling`. So we fall
 * back to `getShortestPaths` + manual walk, matching `playerMachine.coverage.test.ts`.
 */
import { describe, it, expect } from 'vitest'
import { createActor } from 'xstate'
import { getShortestPaths, getStateNodes } from 'xstate/graph'
import { navigationHistoryMachine } from './navigationHistoryMachine'
import type { NavigationHistoryEvent, PositionDescriptor } from './types'

// ---------- helpers --------------------------------------------------------

const pos = (page: number): PositionDescriptor => ({ kind: 'pdf', page, offset: 0 })

/**
 * Events fed into the graph traversal. Deliberately scoped: enough to reach
 * every state node and cross every transition we care about, without blowing
 * up the state space via tons of distinct position payloads.
 *
 * We use a stable handful of positions so `serializeState` collapses visits
 * to the same (region-product, page) into a single graph node.
 */
const TRAVERSAL_EVENTS: readonly NavigationHistoryEvent[] = [
  { type: 'BOOK_OPENED', bookId: 'book1', initialPosition: pos(1) },
  { type: 'BOOK_CLOSED' },
  { type: 'PAGE_VISITED', position: pos(2), ttsContext: null },
  { type: 'PAGE_VISITED', position: pos(1), ttsContext: null },
  {
    type: 'JUMP_REQUESTED',
    from: pos(2),
    fromTts: null,
    to: pos(7),
    source: 'toc',
    fromLabel: 'Chapter 2'
  },
  { type: 'POP_BACK' },
  { type: 'DISMISS_PILL' },
  { type: 'ENGAGEMENT_TAP' },
  { type: 'ENGAGEMENT_TTS_PLAYING' },
  { type: 'DWELL_ELAPSED' },
  { type: 'VISIBILITY_HIDDEN' },
  { type: 'VISIBILITY_VISIBLE' }
] as const

/**
 * Project the snapshot into a compact key. Drops noisy fields that explode
 * the graph (anchor `id` is a fresh UUID per push, `capturedAt` is wall-clock
 * time) — without this, every JUMP_REQUESTED produces a "new" graph node and
 * traversal never terminates.
 *
 * Keeps the dimensions the machine actually branches on:
 *   - `value`           (region product)
 *   - `bookId` presence (inactive vs active)
 *   - `stack.length`    (drives `hasStackEntries` guard + pill hide-on-empty)
 *   - resume-keys       (drives `hasResumeAnchor` guard)
 *   - `currentPage`     (drives PAGE_VISITED routing)
 *   - `pillVisible`     (pill region's bookkeeping)
 */
function serializeState(snapshot: ReturnType<typeof navigationHistoryMachine.transition>): string {
  const c = snapshot.context
  const key = {
    value: snapshot.value,
    book: c.bookId ?? '',
    stackLen: c.stack.length,
    resumeKeys: [...c.resumeMap.keys()].sort(),
    currentPage: c.currentPage,
    pill: c.pillVisible
  }
  return JSON.stringify(key)
}

// ---------- 1. Reachability of every defined state ------------------------

/**
 * Every state node directly defined on the machine should be reachable from
 * the initial state via *some* event sequence. The list is derived from the
 * machine itself (not hardcoded), so adding/renaming a state will be caught
 * here automatically.
 */
describe('navigationHistoryMachine state-graph coverage', () => {
  // Collect human-readable IDs of every state node — root excluded, history
  // nodes excluded. Includes both atomic leaves (e.g. `active.stack.idle`)
  // and the parallel container itself (`active`).
  const targets = getStateNodes(navigationHistoryMachine)
    .filter((n) => n.path.length > 0)
    .filter((n) => n.type !== 'history')
    .map((n) => n.path.join('.'))

  it('discovers state nodes from the machine', () => {
    expect(targets.length).toBeGreaterThan(0)
  })

  for (const stateKey of targets) {
    const paths = getShortestPaths(navigationHistoryMachine, {
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
      const actor = createActor(navigationHistoryMachine)
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

// ---------- 2. Targeted cross-region coverage -----------------------------

/**
 * Walk a generated path into a fresh actor and return the final snapshot.
 */
function walkPath(
  path: ReturnType<typeof getShortestPaths>[number]
): ReturnType<typeof navigationHistoryMachine.transition> {
  const actor = createActor(navigationHistoryMachine)
  actor.start()
  for (const step of path.steps) {
    actor.send(step.event)
  }
  return actor.getSnapshot() as ReturnType<typeof navigationHistoryMachine.transition>
}

describe('navigationHistoryMachine targeted coverage — stack region', () => {
  it('reaches stack.navigating via shortest path and recovers on PAGE_VISITED', () => {
    const paths = getShortestPaths(navigationHistoryMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches({ active: { stack: 'navigating' } })
    })
    expect(paths.length).toBeGreaterThan(0)

    const reachSnap = walkPath(paths[0])
    expect(reachSnap.matches({ active: { stack: 'navigating' } })).toBe(true)
    expect(reachSnap.context.stack.length).toBeGreaterThan(0)

    // Recovery: PAGE_VISITED from navigating drops back to idle and records
    // the visit — this is the "after a jump, the user arrives" path.
    const actor = createActor(navigationHistoryMachine)
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    actor.send({ type: 'PAGE_VISITED', position: pos(7), ttsContext: null })
    const snap = actor.getSnapshot()
    expect(snap.matches({ active: { stack: 'idle' } })).toBe(true)
    expect(snap.context.currentPage).toEqual(pos(7))
  })

  it('POP_BACK with empty stack is a no-op (no transition, no anchor pop)', () => {
    // Sanity: the `hasStackEntries` guard should reject POP_BACK from idle
    // before any JUMP_REQUESTED. Hand-walked (this scenario doesn't otherwise
    // appear as a shortest path because POP_BACK is just ignored).
    const actor = createActor(navigationHistoryMachine)
    actor.start()
    actor.send({ type: 'BOOK_OPENED', bookId: 'book1', initialPosition: pos(1) })
    actor.send({ type: 'POP_BACK' })
    const snap = actor.getSnapshot()
    expect(snap.matches({ active: { stack: 'idle' } })).toBe(true)
    expect(snap.context.stack).toEqual([])
  })
})

describe('navigationHistoryMachine targeted coverage — engagement region', () => {
  it('reaches engagement.paused via VISIBILITY_HIDDEN from dwelling', () => {
    const paths = getShortestPaths(navigationHistoryMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches({ active: { engagement: 'paused' } })
    })
    expect(paths.length).toBeGreaterThan(0)
    const snap = walkPath(paths[0])
    expect(snap.matches({ active: { engagement: 'paused' } })).toBe(true)

    // The shortest path must include VISIBILITY_HIDDEN at some point — this is
    // the only entry into `paused`.
    const eventTypes = paths[0].steps.map((s) => s.event.type)
    expect(eventTypes).toContain('VISIBILITY_HIDDEN')
  })

  it('reaches engagement.engaged and captures a resume anchor', () => {
    const paths = getShortestPaths(navigationHistoryMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches({ active: { engagement: 'engaged' } })
    })
    expect(paths.length).toBeGreaterThan(0)
    const snap = walkPath(paths[0])
    expect(snap.matches({ active: { engagement: 'engaged' } })).toBe(true)
    // `captureResumeAnchor` runs on entry to `engaged`, so resumeMap must
    // have an entry keyed by the current page (assuming currentPage was set).
    if (snap.context.currentPage) {
      expect(snap.context.resumeMap.size).toBeGreaterThan(0)
    }
  })
})

describe('navigationHistoryMachine targeted coverage — pill region', () => {
  it('reaches pill.visible only via JUMP_REQUESTED', () => {
    const paths = getShortestPaths(navigationHistoryMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches({ active: { pill: 'visible' } })
    })
    expect(paths.length).toBeGreaterThan(0)
    const eventTypes = paths[0].steps.map((s) => s.event.type)
    expect(eventTypes).toContain('JUMP_REQUESTED')

    const snap = walkPath(paths[0])
    expect(snap.context.pillVisible).toBe(true)
    expect(snap.context.stack.length).toBeGreaterThan(0)
  })

  it('DISMISS_PILL hides the pill but leaves the stack intact', () => {
    const paths = getShortestPaths(navigationHistoryMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches({ active: { pill: 'visible' } })
    })
    expect(paths.length).toBeGreaterThan(0)

    const actor = createActor(navigationHistoryMachine)
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    const stackBefore = actor.getSnapshot().context.stack.length
    actor.send({ type: 'DISMISS_PILL' })
    const snap = actor.getSnapshot()
    expect(snap.matches({ active: { pill: 'hidden' } })).toBe(true)
    expect(snap.context.pillVisible).toBe(false)
    expect(snap.context.stack.length).toBe(stackBefore)
  })
})

describe('navigationHistoryMachine targeted coverage — cross-region', () => {
  it('POP_BACK that drains the stack also hides the pill', () => {
    // Reach pill.visible with one stacked anchor AND stack region back in
    // `idle` (POP_BACK is only handled in idle). The path search must land
    // a PAGE_VISITED after JUMP_REQUESTED to return stack region to idle.
    const paths = getShortestPaths(navigationHistoryMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) =>
        snapshot.matches({ active: { pill: 'visible', stack: 'idle' } }) &&
        snapshot.context.stack.length === 1
    })
    expect(paths.length).toBeGreaterThan(0)

    const actor = createActor(navigationHistoryMachine)
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    expect(actor.getSnapshot().context.pillVisible).toBe(true)
    expect(actor.getSnapshot().matches({ active: { stack: 'idle' } })).toBe(true)

    actor.send({ type: 'POP_BACK' })
    const snap = actor.getSnapshot()
    expect(snap.context.stack).toEqual([])
    expect(snap.context.pillVisible).toBe(false)
  })

  it('BOOK_CLOSED from any active state returns to inactive with cleared context', () => {
    // Reach a "busy" state in every region: stack has entries, pill visible,
    // engagement past idle. Then close the book.
    const paths = getShortestPaths(navigationHistoryMachine, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) =>
        snapshot.matches('active') &&
        snapshot.context.stack.length > 0 &&
        snapshot.context.pillVisible
    })
    expect(paths.length).toBeGreaterThan(0)

    const actor = createActor(navigationHistoryMachine)
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    actor.send({ type: 'BOOK_CLOSED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('inactive')
    expect(snap.context.bookId).toBeNull()
    expect(snap.context.stack).toEqual([])
    expect(snap.context.resumeMap.size).toBe(0)
    expect(snap.context.pillVisible).toBe(false)
  })
})
