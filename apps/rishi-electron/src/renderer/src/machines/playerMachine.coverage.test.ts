/**
 * State-graph coverage tests for `playerMachine`.
 *
 * The hand-rolled `actor.send(...)` tests in playerMachine.test.ts and
 * playerMachine.recovery.test.ts cover the well-known happy paths but have
 * missed cross-cutting events that recently caused real bugs:
 *
 *   - `NAV_NO_PROGRESS` (auto-advance past last paragraph snap-back — 3299df25)
 *   - `PARAGRAPHS_UPDATED` arriving in unusual states (PDF reading order — f88dc341)
 *   - `PAGE_NAVIGATING` from arbitrary entry points
 *
 * This file uses the `xstate/graph` API (`getShortestPaths` / `getStateNodes`)
 * to (a) prove every top-level state in the machine is reachable from the
 * initial state, and (b) generate paths through `pageNavigating` and
 * `republishingParagraphs` so we exercise their `NAV_NO_PROGRESS` and
 * `PARAGRAPHS_UPDATED` handlers without hand-writing each sequence.
 */
import { describe, it, expect } from 'vitest'
import { createActor, fromCallback } from 'xstate'
import { getShortestPaths, getStateNodes } from 'xstate/graph'
import { playerMachine, type PlayerMachineEvent } from './playerMachine'
import type { ParagraphWithIndex } from '@/stores/playerStore'
import type { ViewActorCommand } from '@/actors/viewActor'

// ---------- helpers --------------------------------------------------------

function makeParagraphs(count: number): ParagraphWithIndex[] {
  return Array.from({ length: count }, (_, i) => ({
    index: `p-${i}`,
    text: `Paragraph ${i}`
  }))
}

const SAMPLE_PARAGRAPHS = makeParagraphs(2)
const SAMPLE_NEXT = [{ index: 'n-0', text: 'Next' }]
const SAMPLE_PREV = [{ index: 'pv-0', text: 'Prev' }]

/**
 * Events fed into the graph traversal. Deliberately scoped: we want coverage
 * of the bug-prone events without exploding the state space. PARAGRAPHS_UPDATED
 * appears twice (different shapes) so the traversal can pick a refresh after
 * a page nav distinct from the initial publish.
 */
const TRAVERSAL_EVENTS: readonly PlayerMachineEvent[] = [
  { type: 'INITIALIZE', bookId: 'book1' },
  { type: 'PARAGRAPHS_UPDATED', paragraphs: SAMPLE_PARAGRAPHS },
  { type: 'NEXT_PARAGRAPHS_UPDATED', paragraphs: SAMPLE_NEXT },
  { type: 'PREV_PARAGRAPHS_UPDATED', paragraphs: SAMPLE_PREV },
  { type: 'PLAY' },
  { type: 'PAUSE' },
  { type: 'RESUME' },
  { type: 'STOP' },
  { type: 'NEXT' },
  { type: 'PREV' },
  { type: 'REPEAT' },
  { type: 'AUDIO_LOADED' },
  { type: 'AUDIO_ENDED' },
  { type: 'AUDIO_ERROR', error: 'boom' },
  { type: 'CHAT_STARTED' },
  { type: 'CHAT_ENDED' },
  { type: 'PAGE_NAVIGATING', direction: 'forward' },
  { type: 'NAV_NO_PROGRESS', reason: 'end-of-document' },
  {
    type: 'PLAY_FROM',
    paragraphIndex: 1,
    partialFirstText: 'partial',
    partialFirstKey: 'p-1'
  }
] as const

/**
 * Project the snapshot into a compact key that drops the bulk-data arrays
 * (`currentParagraphs`, `nextPageParagraphs`, `prevPageParagraphs`, `errors`)
 * from the graph's notion of "same state". Without this the array identities
 * make every visit look unique and traversal explodes.
 */
function serializeState(snapshot: ReturnType<typeof playerMachine.transition>): string {
  const c = snapshot.context
  const key = {
    value: snapshot.value,
    bookId: c.bookId || '',
    pIdx: c.paragraphIndex,
    pLen: c.currentParagraphs.length,
    dir: c.direction,
    retry: c.retryCount,
    timedOut: c.timedOut,
    war: c.wantsAutoResume,
    waric: c.wantsAutoResumeAfterChat,
    pFirst: c.partialFirstParagraphIndex,
    resume: c.resumeParagraphIndex
  }
  return JSON.stringify(key)
}

/**
 * Mock view actor: silent. Lets PAGE_NAVIGATING / waitingForParagraphs paths
 * traverse without hanging on view-actor sendBack. The graph traversal feeds
 * PARAGRAPHS_UPDATED / NAV_NO_PROGRESS directly as parent events.
 */
const silentView = fromCallback<ViewActorCommand, unknown>(() => () => {})

const machineUnderTest = playerMachine.provide({ actors: { view: silentView } })

// ---------- 1. Reachability of every defined state -------------------------

/**
 * Every state node directly defined on the machine should be reachable from
 * the initial state via *some* event sequence. The list is derived from the
 * machine itself (not hardcoded), so adding/renaming a state will be caught
 * here automatically.
 */
describe('playerMachine state-graph coverage', () => {
  // v5 API note: `createTestModel(machine)` validates the machine and throws
  // "Invocations on test machines are not supported" — our machine invokes
  // the `view` actor, so we can't use the TestModel/path.test pattern here.
  // (`path.test({ states, events })` is also designed for an *external* SUT,
  // which we don't have — the actor itself is the SUT.) Per the task's
  // fallback guidance: use `getShortestPaths` directly, but adopt the
  // per-state `it()` shape so failures name the offending state instead of
  // surfacing an opaque "[a, b] !== []" diff.

  // Collect the human-readable IDs of every state node that's actually a
  // "place the machine can be in". We filter out the root + any history
  // nodes / final-only descendants; we want plain atomic & compound states.
  const targets = getStateNodes(playerMachine)
    // skip the root node (`#player`) itself
    .filter((n) => n.path.length > 0)
    // skip parallel-region placeholders and pseudo nodes
    .filter((n) => n.type !== 'history')
    .map((n) => n.path.join('.'))

  it('discovers state nodes from the machine', () => {
    expect(targets.length).toBeGreaterThan(0)
  })

  // One `it` per state node — failure pinpoints the exact unreachable state
  // (or the exact path whose walk diverges from the graph's prediction).
  for (const stateKey of targets) {
    // `matches` is typed against the literal state union; the iteration key
    // is `string`, so widen via `as never`.
    const paths = getShortestPaths(machineUnderTest, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches(stateKey as never)
    })

    if (paths.length === 0) {
      // Generate a failing test so the reporter shows *which* state is
      // unreachable rather than dumping a "[a, b] !== []" array diff.
      it(`reaches ${stateKey}`, () => {
        throw new Error(`no shortest path reaches state "${stateKey}"`)
      })
      continue
    }

    // Use the canonical shortest path. v5's `getShortestPaths` returns plain
    // `StatePath` objects (no `description` field — that lives on the
    // TestModel-flavoured `TestPath`), so we synthesize one from the event
    // sequence for the test name.
    const path = paths[0]
    const description = path.steps.map((s) => s.event.type).join(' -> ') || '<initial>'
    it(`reaches ${stateKey} via ${description}`, () => {
      const actor = createActor(machineUnderTest)
      actor.start()
      for (const step of path.steps) {
        actor.send(step.event)
      }
      const snap = actor.getSnapshot()
      expect(
        snap.matches(stateKey as never),
        `walked shortest path to "${stateKey}" but actor landed in ${JSON.stringify(
          snap.value
        )}`
      ).toBe(true)
    })
  }
})

// ---------- 2. Targeted path coverage --------------------------------------

/**
 * Walk a generated path by feeding events into a fresh actor. Asserts each
 * event lands on a snapshot whose machine `value` matches the path's record
 * of the post-event state — i.e. the actor and the graph agree.
 *
 * Returns the final snapshot so callers can assert end-state shape.
 */
function walkPath(path: ReturnType<typeof getShortestPaths>[number]): ReturnType<
  typeof playerMachine.transition
> {
  const actor = createActor(machineUnderTest)
  actor.start()
  for (const step of path.steps) {
    actor.send(step.event)
  }
  return actor.getSnapshot() as ReturnType<typeof playerMachine.transition>
}

describe('playerMachine targeted coverage — pageNavigating', () => {
  it('reaches pageNavigating via shortest path and accepts NAV_NO_PROGRESS', () => {
    const paths = getShortestPaths(machineUnderTest, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches('pageNavigating')
    })
    expect(paths.length).toBeGreaterThan(0)

    // Walk the canonical shortest path, then send NAV_NO_PROGRESS as the
    // recovery event. This is the regression path for commit 3299df25.
    const reachSnap = walkPath(paths[0])
    expect(reachSnap.matches('pageNavigating')).toBe(true)

    const actor = createActor(machineUnderTest)
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    actor.send({ type: 'NAV_NO_PROGRESS', reason: 'end-of-document' })

    const snap = actor.getSnapshot()
    expect(snap.value).toBe('stopped')
    expect(snap.context.wantsAutoResume).toBe(false)
    expect(snap.context.paragraphIndex).toBe(0)
    expect(snap.context.partialFirstText).toBeNull()
  })

  it('every shortest path through pageNavigating can recover via PARAGRAPHS_UPDATED', () => {
    const paths = getShortestPaths(machineUnderTest, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches('pageNavigating')
    })
    expect(paths.length).toBeGreaterThan(0)

    for (const path of paths) {
      const actor = createActor(machineUnderTest)
      actor.start()
      let threw: unknown = null
      try {
        for (const step of path.steps) actor.send(step.event)
        // From pageNavigating, fresh paragraphs should always route to either
        // `loading` (if wantsAutoResume was set) or `stopped` (if not).
        actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      } catch (e) {
        threw = e
      }
      expect(threw).toBeNull()

      const snap = actor.getSnapshot()
      const valueStr = JSON.stringify(snap.value)
      // Either we resumed loading or fell into stopped — never stuck.
      const ok = snap.matches('loading') || snap.matches('stopped')
      expect(
        ok,
        `path landed in ${valueStr} after PARAGRAPHS_UPDATED; expected loading|stopped`
      ).toBe(true)
      // Bookkeeping: wantsAutoResume must be cleared once we leave pageNavigating.
      expect(snap.context.wantsAutoResume).toBe(false)
    }
  })
})

describe('playerMachine targeted coverage — republishingParagraphs', () => {
  it('reaches republishingParagraphs and routes correctly on both outcomes', () => {
    const paths = getShortestPaths(machineUnderTest, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches('republishingParagraphs')
    })
    expect(paths.length).toBeGreaterThan(0)

    // Outcome A: republish succeeded → PARAGRAPHS_UPDATED → loading.
    {
      const actor = createActor(machineUnderTest)
      actor.start()
      for (const step of paths[0].steps) actor.send(step.event)
      expect(actor.getSnapshot().matches('republishingParagraphs')).toBe(true)
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(2) })
      expect(actor.getSnapshot().value).toBe('loading')
      expect(actor.getSnapshot().context.currentParagraphs).toHaveLength(2)
    }

    // Outcome B: republish bailed (image-only / same view) → NAV_NO_PROGRESS
    // → stopped. This is the f88dc341 regression class (PDF reading order
    // edge cases that emit empty views).
    {
      const actor = createActor(machineUnderTest)
      actor.start()
      for (const step of paths[0].steps) actor.send(step.event)
      actor.send({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('stopped')
      expect(snap.context.paragraphIndex).toBe(0)
      expect(snap.context.partialFirstText).toBeNull()
    }
  })
})

describe('playerMachine targeted coverage — waitingForParagraphs', () => {
  it('NAV_NO_PROGRESS from waitingForParagraphs lands in stopped with cleared flags', () => {
    const paths = getShortestPaths(machineUnderTest, {
      events: TRAVERSAL_EVENTS,
      serializeState,
      toState: (snapshot) => snapshot.matches('waitingForParagraphs')
    })
    expect(paths.length).toBeGreaterThan(0)

    const actor = createActor(machineUnderTest)
    actor.start()
    for (const step of paths[0].steps) actor.send(step.event)
    expect(actor.getSnapshot().matches('waitingForParagraphs')).toBe(true)

    actor.send({ type: 'NAV_NO_PROGRESS', reason: 'end-of-document' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('stopped')
    // Per the machine: NAV_NO_PROGRESS handler runs resetIndex,
    // clearWantsAutoResume, clearPartialFirst.
    expect(snap.context.paragraphIndex).toBe(0)
    expect(snap.context.wantsAutoResume).toBe(false)
    expect(snap.context.partialFirstText).toBeNull()
  })
})
