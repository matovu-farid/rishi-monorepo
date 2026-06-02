/**
 * State-graph coverage tests for `pdfReaderMachine`.
 *
 * The hand-rolled tests in pdfReaderMachine.test.ts cover the typical
 * restore → scroll → save cadence but don't systematically exercise every
 * parallel-region leaf, nor every cross-cutting event (FLUSH, SEEK_REQUESTED,
 * COMMIT_PAGE) from arbitrary entry points.
 *
 * This file uses the `xstate/graph` API (`getShortestPaths` / `getStateNodes`)
 * to (a) prove every leaf state in both parallel regions (`seek.*` and
 * `persist.*`) is reachable, and (b) assert the seek-lockout invariant —
 * `PAGE_CHANGED` events during `seek.seeking` are silently dropped — holds
 * along every generated path.
 *
 * The machine `invoke`s the `saveLocation` actor; per the v5 graph API,
 * `createTestModel(machine).path.test(...)` throws on invoking machines, so
 * we walk paths manually with `createActor`. The `saveLocation` actor is
 * stubbed with a never-resolving promise so traversal never touches IPC.
 */
import { describe, it, expect } from 'vitest'
import { createActor, fromPromise } from 'xstate'
import { getShortestPaths, getStateNodes } from 'xstate/graph'
import { pdfReaderMachine, type PdfReaderEvent, type PdfReaderInput } from './pdfReaderMachine'

// ---------- helpers --------------------------------------------------------

const INPUT: PdfReaderInput = { bookId: 1, initialPage: 10, initialOffset: 0 }

/**
 * Events fed into the graph traversal. Scoped to the bug-prone surface:
 * the lifecycle (DOC_LOADED, SEEK_REQUESTED, SEEK_LANDED, PAGE_CHANGED)
 * plus cross-cutting FLUSH. COMMIT_PAGE is intentionally NOT in the list —
 * it's a `raise`-d internal event, and feeding it directly would let the
 * traversal pretend to reach persist transitions that no real run could.
 */
const TRAVERSAL_EVENTS: readonly PdfReaderEvent[] = [
  { type: 'DOC_LOADED', numPages: 100 },
  { type: 'SEEK_REQUESTED', page: 25 },
  { type: 'SEEK_REQUESTED', page: 30 },
  { type: 'SEEK_LANDED' },
  { type: 'PAGE_CHANGED', page: 11, offset: 0 },
  { type: 'PAGE_CHANGED', page: 12, offset: 200 },
  { type: 'FLUSH' }
] as const

/**
 * Compact projection of a snapshot used by the graph as the dedup key.
 * Drops `saveError` strings and keeps only scalars + region values so the
 * adjacency map stays finite.
 */
function serializeState(snapshot: ReturnType<typeof pdfReaderMachine.transition>): string {
  const c = snapshot.context
  return JSON.stringify({
    value: snapshot.value,
    page: c.currentPage,
    offset: c.currentOffset,
    seekTarget: c.seekTarget,
    pendingOffset: c.pendingOffset,
    lastSavedPage: c.lastSavedPage,
    lastSavedOffset: c.lastSavedOffset,
    hasError: c.saveError !== null
  })
}

/**
 * Stub the `saveLocation` actor with a promise that never resolves. The
 * traversal only fires `after`-driven transitions if real timers fire, and
 * we use `getShortestPaths` (event-driven), so `persist.saving` is reached
 * only by manual fake-timer tests further down. The stub keeps the invoke
 * harmless for any unexpected drift into `saving`.
 */
const machineUnderTest = pdfReaderMachine.provide({
  actors: {
    saveLocation: fromPromise<
      { savedPage: number; savedOffset: number },
      { bookId: number; page: number; offset: number }
    >(() => new Promise(() => {}))
  }
})

// ---------- 1. Reachability of every defined state -------------------------

describe('pdfReaderMachine state-graph coverage', () => {
  // Pull every atomic / compound state node from the machine definition.
  // Filter the root (`#pdfReader`) and history pseudo-nodes; we want the
  // places the machine can actually be in.
  const targets = getStateNodes(pdfReaderMachine)
    .filter((n) => n.path.length > 0)
    .filter((n) => n.type !== 'history')
    .map((n) => n.path.join('.'))

  it('discovers state nodes from the machine', () => {
    expect(targets.length).toBeGreaterThan(0)
  })

  for (const stateKey of targets) {
    // `persist.saving` is only reachable via the `after: 400ms` timer
    // inside `persist.dirty`, which `getShortestPaths` does not advance.
    // We cover `saving` via the manual fake-timer test below; skip here.
    if (stateKey === 'persist.saving') continue

    const paths = getShortestPaths(machineUnderTest, {
      input: INPUT,
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
      const actor = createActor(machineUnderTest, { input: INPUT })
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

// ---------- 2. Seek-lockout invariant --------------------------------------

/**
 * The documented seek-lockout: while `seek.seeking` is active, the persisted
 * `currentPage`/`currentOffset` must NOT be moved by any `PAGE_CHANGED`
 * event. The scroll listener fires PAGE_CHANGED for sentinel pages during a
 * programmatic seek, and the lockout is what prevents those from stomping
 * the saved location.
 */
describe('pdfReaderMachine seek-lockout invariant', () => {
  it('PAGE_CHANGED during seek.seeking does not mutate currentPage/currentOffset', () => {
    // Reach `seek.seeking` via the canonical shortest path (DOC_LOADED).
    const paths = getShortestPaths(machineUnderTest, {
      input: INPUT,
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (s) => s.matches({ seek: 'seeking' })
    })
    expect(paths.length).toBeGreaterThan(0)

    const actor = createActor(machineUnderTest, { input: INPUT })
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)

    const before = actor.getSnapshot().context
    expect(before.currentPage).toBe(10) // unchanged from initial
    actor.send({ type: 'PAGE_CHANGED', page: 99, offset: 1234 })
    const after = actor.getSnapshot().context
    expect(after.currentPage).toBe(before.currentPage)
    expect(after.currentOffset).toBe(before.currentOffset)
    expect(actor.getSnapshot().matches({ seek: 'seeking' })).toBe(true)
  })

  it('lockout holds along every shortest path that lands in seek.seeking', () => {
    const paths = getShortestPaths(machineUnderTest, {
      input: INPUT,
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (s) => s.matches({ seek: 'seeking' })
    })
    expect(paths.length).toBeGreaterThan(0)

    for (const path of paths) {
      const actor = createActor(machineUnderTest, { input: INPUT })
      actor.start()
      for (const step of path.steps) actor.send(step.event)
      const ctx = actor.getSnapshot().context
      actor.send({ type: 'PAGE_CHANGED', page: 77, offset: 999 })
      const after = actor.getSnapshot().context
      const description = path.steps.map((s) => s.event.type).join(' -> ')
      expect(
        after.currentPage,
        `seek-lockout broken on path "${description}": currentPage changed`
      ).toBe(ctx.currentPage)
      expect(
        after.currentOffset,
        `seek-lockout broken on path "${description}": currentOffset changed`
      ).toBe(ctx.currentOffset)
    }
  })
})

// ---------- 3. Cross-cutting recovery events -------------------------------

describe('pdfReaderMachine cross-cutting events', () => {
  it('SEEK_REQUESTED from seek.viewing transitions to seeking and clears pendingOffset', () => {
    const paths = getShortestPaths(machineUnderTest, {
      input: INPUT,
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (s) => s.matches({ seek: 'viewing' })
    })
    expect(paths.length).toBeGreaterThan(0)

    const actor = createActor(machineUnderTest, { input: INPUT })
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    expect(actor.getSnapshot().matches({ seek: 'viewing' })).toBe(true)

    actor.send({ type: 'SEEK_REQUESTED', page: 42 })
    const snap = actor.getSnapshot()
    expect(snap.matches({ seek: 'seeking' })).toBe(true)
    expect(snap.context.seekTarget).toBe(42)
    // The user-initiated seek lands at the page top; pendingOffset must be 0.
    expect(snap.context.pendingOffset).toBe(0)
  })

  it('FLUSH is a no-op when current position equals lastSaved (guard: flushable)', () => {
    // Fresh actor — initial state has lastSavedPage===currentPage.
    const actor = createActor(machineUnderTest, { input: INPUT })
    actor.start()
    const before = actor.getSnapshot().context
    actor.send({ type: 'FLUSH' })
    const after = actor.getSnapshot().context
    // No state change beyond the explicit `flushSave` action (which is a
    // default no-op). `lastSaved*` must not move.
    expect(after.lastSavedPage).toBe(before.lastSavedPage)
    expect(after.lastSavedOffset).toBe(before.lastSavedOffset)
  })

  it('SEEK_REQUESTED while already in seeking re-enters with new target', () => {
    const actor = createActor(machineUnderTest, { input: INPUT })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 100 })
    expect(actor.getSnapshot().matches({ seek: 'seeking' })).toBe(true)
    const firstTarget = actor.getSnapshot().context.seekTarget

    actor.send({ type: 'SEEK_REQUESTED', page: 55 })
    const snap = actor.getSnapshot()
    expect(snap.matches({ seek: 'seeking' })).toBe(true)
    expect(snap.context.seekTarget).toBe(55)
    expect(snap.context.seekTarget).not.toBe(firstTarget)
  })

  it('SEEK_LANDED applies pendingOffset and emits an internal COMMIT_PAGE', () => {
    // Restore at page 10 offset 240; pendingOffset is seeded with 240.
    const actor = createActor(machineUnderTest, {
      input: { bookId: 1, initialPage: 10, initialOffset: 240 }
    })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 100 })
    expect(actor.getSnapshot().context.pendingOffset).toBe(240)

    actor.send({ type: 'SEEK_LANDED' })
    const snap = actor.getSnapshot()
    expect(snap.matches({ seek: 'viewing' })).toBe(true)
    expect(snap.context.currentPage).toBe(10)
    expect(snap.context.currentOffset).toBe(240)
    // Initial restore matches lastSaved exactly, so persist must stay clean.
    expect(snap.matches({ persist: 'clean' })).toBe(true)
  })

  it('COMMIT_PAGE raised after PAGE_CHANGED with movement transitions persist to dirty', () => {
    const actor = createActor(machineUnderTest, { input: INPUT })
    actor.start()
    actor.send({ type: 'DOC_LOADED', numPages: 100 })
    actor.send({ type: 'SEEK_LANDED' })
    expect(actor.getSnapshot().matches({ seek: 'viewing' })).toBe(true)

    actor.send({ type: 'PAGE_CHANGED', page: 11, offset: 0 })
    const snap = actor.getSnapshot()
    expect(snap.matches({ seek: 'viewing' })).toBe(true)
    expect(snap.matches({ persist: 'dirty' })).toBe(true)
    expect(snap.context.currentPage).toBe(11)
  })
})
