/**
 * State-graph coverage tests for `navMachine`.
 *
 * This is the FIRST test file for `navMachine`. It uses the `xstate/graph`
 * API to prove every defined state is reachable, and exercises each
 * transition (including both branches of the guarded `CURL_COMMIT` and the
 * `CURL_CANCEL → undoing` recovery path).
 *
 * v5 API note: this machine has `after: { 30000: 'idle' }` safety timeouts
 * on three states (`navigating`, `settling`, `undoing`). `createTestModel`
 * throws on `after`, so we use `getShortestPaths` directly and walk paths
 * manually. Where we need to verify a timeout fires, we use vitest fake
 * timers.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { createActor } from 'xstate'
import { getShortestPaths, getStateNodes } from 'xstate/graph'
import { navMachine, type NavMachineEvent } from './navMachine'

// ---------- helpers --------------------------------------------------------

/**
 * Events fed into the graph traversal. Includes every event the machine
 * accepts so traversal can reach all five states.
 */
const TRAVERSAL_EVENTS: readonly NavMachineEvent[] = [
  { type: 'NEXT' },
  { type: 'PREV' },
  { type: 'DISPLAY', location: 'cfi/2/4' },
  { type: 'CURL_NEXT' },
  { type: 'CURL_PREV' },
  { type: 'CURL_COMMIT' },
  { type: 'CURL_CANCEL' },
  { type: 'SETTLED' }
] as const

/**
 * Compact snapshot key for graph traversal. Drops `version` (monotonic, would
 * make every visit unique) and `pendingLocation` (string churn). Keeps
 * pendingAction / curlDirection / curlSettled because they affect transitions.
 */
function serializeState(snapshot: ReturnType<typeof navMachine.transition>): string {
  const c = snapshot.context
  return JSON.stringify({
    value: snapshot.value,
    pendingAction: c.pendingAction,
    curlDirection: c.curlDirection,
    curlSettled: c.curlSettled
  })
}

// ---------- 1. Reachability of every defined state -------------------------

describe('navMachine state-graph coverage', () => {
  const targets = getStateNodes(navMachine)
    .filter((n) => n.path.length > 0)
    .filter((n) => n.type !== 'history')
    .map((n) => n.path.join('.'))

  it('discovers all 5 state nodes from the machine', () => {
    expect(targets).toEqual(
      expect.arrayContaining(['idle', 'navigating', 'curling', 'settling', 'undoing'])
    )
    expect(targets).toHaveLength(5)
  })

  for (const stateKey of targets) {
    const paths = getShortestPaths(navMachine, {
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
      const actor = createActor(navMachine)
      actor.start()
      for (const step of path.steps) actor.send(step.event)
      const snap = actor.getSnapshot()
      expect(
        snap.matches(stateKey as never),
        `walked shortest path to "${stateKey}" but actor landed in ${JSON.stringify(snap.value)}`
      ).toBe(true)
    })
  }
})

// ---------- 2. Targeted transition coverage --------------------------------

describe('navMachine transitions from idle', () => {
  it('NEXT: idle → navigating, sets pendingAction=next, bumps version', () => {
    const actor = createActor(navMachine)
    actor.start()
    const v0 = actor.getSnapshot().context.version
    actor.send({ type: 'NEXT' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('navigating')
    expect(snap.context.pendingAction).toBe('next')
    expect(snap.context.pendingLocation).toBeNull()
    expect(snap.context.version).toBe(v0 + 1)
  })

  it('PREV: idle → navigating, sets pendingAction=prev', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'PREV' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('navigating')
    expect(snap.context.pendingAction).toBe('prev')
  })

  it('DISPLAY: idle → navigating, sets pendingLocation', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'DISPLAY', location: 'epubcfi(/6/4!/4/2/2)' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('navigating')
    expect(snap.context.pendingAction).toBe('display')
    expect(snap.context.pendingLocation).toBe('epubcfi(/6/4!/4/2/2)')
  })

  it('CURL_NEXT: idle → curling, sets curlDirection=next and clears curlSettled', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('curling')
    expect(snap.context.pendingAction).toBe('next')
    expect(snap.context.curlDirection).toBe('next')
    expect(snap.context.curlSettled).toBe(false)
  })

  it('CURL_PREV: idle → curling, sets curlDirection=prev', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_PREV' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('curling')
    expect(snap.context.curlDirection).toBe('prev')
  })
})

describe('navMachine — navigating state', () => {
  it('SETTLED returns to idle', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'SETTLED' })
    expect(actor.getSnapshot().value).toBe('idle')
  })
})

describe('navMachine — curling state, CURL_COMMIT guarded branches', () => {
  it('committed branch: CURL_COMMIT without prior SETTLED routes to settling', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' })
    expect(actor.getSnapshot().context.curlSettled).toBe(false)
    actor.send({ type: 'CURL_COMMIT' })
    expect(actor.getSnapshot().value).toBe('settling')
  })

  it('committed branch (fast path): SETTLED while curling → CURL_COMMIT → idle', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' })
    // SETTLED while curling marks curlSettled=true but stays in curling
    actor.send({ type: 'SETTLED' })
    const mid = actor.getSnapshot()
    expect(mid.value).toBe('curling')
    expect(mid.context.curlSettled).toBe(true)
    // Now CURL_COMMIT should go straight to idle (guard isCurlSettled)
    actor.send({ type: 'CURL_COMMIT' })
    expect(actor.getSnapshot().value).toBe('idle')
  })

  it('reverted branch: CURL_CANCEL → undoing, flips pendingAction, clears curlDirection', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' }) // curlDirection=next
    actor.send({ type: 'CURL_CANCEL' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('undoing')
    // setUndoCurl: flips next ↔ prev so the rendition reverses the curl
    expect(snap.context.pendingAction).toBe('prev')
    expect(snap.context.curlDirection).toBeNull()
  })

  it('reverted branch from CURL_PREV: undoing pendingAction=next', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_PREV' }) // curlDirection=prev
    actor.send({ type: 'CURL_CANCEL' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('undoing')
    expect(snap.context.pendingAction).toBe('next')
    expect(snap.context.curlDirection).toBeNull()
  })
})

describe('navMachine — settling & undoing recovery', () => {
  it('settling: SETTLED → idle', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' })
    actor.send({ type: 'CURL_COMMIT' }) // → settling (guard false)
    expect(actor.getSnapshot().value).toBe('settling')
    actor.send({ type: 'SETTLED' })
    expect(actor.getSnapshot().value).toBe('idle')
  })

  it('undoing: SETTLED → idle', () => {
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' })
    actor.send({ type: 'CURL_CANCEL' })
    expect(actor.getSnapshot().value).toBe('undoing')
    actor.send({ type: 'SETTLED' })
    expect(actor.getSnapshot().value).toBe('idle')
  })
})

describe('navMachine — global DISPLAY interrupt', () => {
  // DISPLAY is defined on the root `on` so it must preempt every state. We
  // table-drive the four non-idle states rather than write 4 near-identical its.
  const setups: Array<[string, (a: ReturnType<typeof createActor<typeof navMachine>>) => void]> = [
    ['navigating', (a) => a.send({ type: 'NEXT' })],
    ['curling', (a) => a.send({ type: 'CURL_NEXT' })],
    [
      'settling',
      (a) => {
        a.send({ type: 'CURL_NEXT' })
        a.send({ type: 'CURL_COMMIT' })
      }
    ],
    [
      'undoing',
      (a) => {
        a.send({ type: 'CURL_NEXT' })
        a.send({ type: 'CURL_CANCEL' })
      }
    ]
  ]
  for (const [from, setup] of setups) {
    it(`DISPLAY from ${from} preempts into navigating with new location`, () => {
      const actor = createActor(navMachine)
      actor.start()
      setup(actor)
      expect(actor.getSnapshot().value).toBe(from)
      actor.send({ type: 'DISPLAY', location: 'jump' })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('navigating')
      expect(snap.context.pendingAction).toBe('display')
      expect(snap.context.pendingLocation).toBe('jump')
    })
  }
})

// ---------- 3. `after` safety timeouts (fake timers) -----------------------

describe('navMachine — after safety timeouts', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('navigating times out to idle after 30s if no SETTLED arrives', () => {
    vi.useFakeTimers()
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('navigating')
    vi.advanceTimersByTime(30_000)
    expect(actor.getSnapshot().value).toBe('idle')
  })

  it('settling times out to idle after 30s', () => {
    vi.useFakeTimers()
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' })
    actor.send({ type: 'CURL_COMMIT' })
    expect(actor.getSnapshot().value).toBe('settling')
    vi.advanceTimersByTime(30_000)
    expect(actor.getSnapshot().value).toBe('idle')
  })

  it('undoing times out to idle after 30s', () => {
    vi.useFakeTimers()
    const actor = createActor(navMachine)
    actor.start()
    actor.send({ type: 'CURL_NEXT' })
    actor.send({ type: 'CURL_CANCEL' })
    expect(actor.getSnapshot().value).toBe('undoing')
    vi.advanceTimersByTime(30_000)
    expect(actor.getSnapshot().value).toBe('idle')
  })
})
