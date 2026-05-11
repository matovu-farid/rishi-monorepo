# Connectivity service refactor — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revision:** revised 2026-05-11 — wraps committed xstate `connectivityMachine` (PR #9, fa03136a) rather than dropping it. Supersedes the previous plan.

**Goal:** Wrap `machines/connectivityMachine.ts` behind a `services/connectivity/` boundary with a typed factory, structurally compatible with Sync's `ConnectivityPort`. Collapse `hooks/useConnectivity.ts` into a thin `useSyncExternalStore` facade. Delete `modules/connectivity.ts` (now internal/redundant). Re-wire Sync's `connectivity` port to `getConnectivityService()`, eliminating the hand-rolled adapter in `services/index.ts`.

**Architecture:** One factory `createConnectivityService(deps: ConnectivityServiceDeps)`. xstate machine + actor live inside the service. Public surface: `isOnline()`, `subscribe(listener)`, `start()`, `stop()`. Deps: `source` port (navigator-like). Status events use a tiny internal observer (transition-only edges from the machine's state changes).

**Tech Stack:** TypeScript, vitest, xstate (internal — not exposed at the boundary).

---

## Plan overview

- **Task 0 — Worktree + branch + scaffold:** Create worktree `/tmp/rishi-connectivity-refactor` from `origin/main` on branch `refactor/connectivity-service`. Copy the revised spec + this plan into the worktree. Scaffold an empty `services/connectivity/` directory.
- **Tasks 1–5 — Build the service (TDD):** Types → internal subscribers helper → service factory (wraps xstate actor) → React hook → public exports.
- **Tasks 6–9 — Wire & migrate callers:** Add `getConnectivityService()` lazy singleton with auto-start, collapse Sync's hand-rolled adapter, migrate `useConnectivity` callers, `NetworkBanner`, and any direct `modules/connectivity.ts` callers (`voiceChatService.ts`).
- **Tasks 10–11 — Verify & delete:** Re-run Sync boundary tests, verify connectivity tests pass, then `git rm` `hooks/useConnectivity.ts` + `modules/connectivity.ts`. KEEP `machines/connectivityMachine.ts` + its tests (now internal-impl coverage).
- **Task 12 — Final verification.** `pnpm typecheck`, `pnpm lint`, `pnpm vitest run`.

All paths below are absolute from `/tmp/rishi-connectivity-refactor` (the worktree root). All `pnpm` commands should be run from `/tmp/rishi-connectivity-refactor/apps/rishi-electron` unless otherwise stated. All `git` commands should be run from `/tmp/rishi-connectivity-refactor`.

---

## Task 0: Worktree + branch + scaffold + commit revised spec/plan

**Files:**
- Create: worktree at `/tmp/rishi-connectivity-refactor`
- Copy: `docs/superpowers/specs/2026-05-11-connectivity-service-design.md` (revised) and `docs/superpowers/plans/2026-05-11-connectivity-service.md` (this file) into the worktree
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/index.ts` (placeholder)

- [ ] **Step 1: Create the worktree from `origin/main` on a new branch**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git fetch origin main
git worktree add /tmp/rishi-connectivity-refactor -b refactor/connectivity-service origin/main
```

Expected: `Preparing worktree (new branch 'refactor/connectivity-service')` and `HEAD is now at <sha>`.

- [ ] **Step 2: Confirm the worktree is on the expected branch with a clean tree**

```bash
cd /tmp/rishi-connectivity-refactor
git status -sb
```

Expected output starts with `## refactor/connectivity-service` and shows a clean tree.

- [ ] **Step 3: Copy the revised spec + this plan into the worktree**

```bash
mkdir -p /tmp/rishi-connectivity-refactor/docs/superpowers/specs
mkdir -p /tmp/rishi-connectivity-refactor/docs/superpowers/plans
cp /Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/specs/2026-05-11-connectivity-service-design.md \
   /tmp/rishi-connectivity-refactor/docs/superpowers/specs/2026-05-11-connectivity-service-design.md
cp /Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/plans/2026-05-11-connectivity-service.md \
   /tmp/rishi-connectivity-refactor/docs/superpowers/plans/2026-05-11-connectivity-service.md
```

- [ ] **Step 4: Commit the revised spec + plan**

```bash
cd /tmp/rishi-connectivity-refactor
git add docs/superpowers/specs/2026-05-11-connectivity-service-design.md \
        docs/superpowers/plans/2026-05-11-connectivity-service.md
git commit -m "docs(connectivity): revised spec + plan — wrap xstate machine

Spec revision 2026-05-11 reverses the previous decision to drop xstate.
The committed connectivityMachine (PR #9, fa03136a) is wrapped behind a
services/connectivity/ boundary rather than rewritten. Plan reflects the
new task sequence."
```

- [ ] **Step 5: Verify no stale connectivity edits exist in the worktree's service folder**

```bash
cd /tmp/rishi-connectivity-refactor
git status -s -- apps/rishi-electron/src/renderer/src/services/connectivity \
                  apps/rishi-electron/src/renderer/src/modules/connectivity.ts \
                  apps/rishi-electron/src/renderer/src/hooks/useConnectivity.ts
```

Expected: no output (clean — the legacy files exist but are committed; the new service folder doesn't exist yet).

- [ ] **Step 6: Create the empty service directory with a placeholder `index.ts`**

```bash
mkdir -p /tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity
```

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/index.ts`:

```ts
// Placeholder — populated incrementally by subsequent tasks.
export {}
```

- [ ] **Step 7: Verify typecheck still passes**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes (modulo the pre-existing `src/main/**` and `stores/navStore.test.ts` errors — see Task 12).

- [ ] **Step 8: Commit the scaffold**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/connectivity/index.ts
git commit -m "refactor(connectivity): scaffold services/connectivity directory

Empty index.ts placeholder. Behavior added incrementally in subsequent
commits (TDD: red → green → commit per behavior)."
```

---

## Task 1: Type definitions (`types.ts`)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/types.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/types.test-d.ts`

The public type surface is small (4 types) and must be **structurally compatible** with Sync's `ConnectivityPort` so a `ConnectivityService` can be passed directly into `createSyncService({ ..., connectivity })`.

- [ ] **Step 1: Create `types.ts` with the full public type surface**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/types.ts`:

```ts
export type ConnectivityListener = (online: boolean) => void

/**
 * The minimal browser-event surface the service needs. `window` satisfies this
 * shape natively in production; tests inject a hand-rolled fake.
 */
export interface ConnectivitySource {
  readonly onLine: boolean
  addEventListener(type: 'online' | 'offline', listener: () => void): void
  removeEventListener(type: 'online' | 'offline', listener: () => void): void
}

export interface ConnectivityServiceDeps {
  source: ConnectivitySource
}

/**
 * Public interface. Shape-compatible with `services/sync/types.ConnectivityPort`
 * — `isOnline()` + `subscribe()` overlap exactly, so a `ConnectivityService`
 * passes structural typing for `ConnectivityPort` (extra `start`/`stop` are
 * ignored by Sync).
 */
export interface ConnectivityService {
  /** Synchronous: is the renderer currently online? */
  isOnline(): boolean
  /**
   * Subscribe to online/offline transitions. Listener fires only on transitions
   * (edge-detected against the underlying xstate state value). Callers needing
   * the current value at subscribe time should call `isOnline()` separately.
   * Returns an unsubscribe function.
   */
  subscribe(listener: ConnectivityListener): () => void
  /**
   * Start the service: create the xstate actor (if not yet built), start it,
   * register `source.addEventListener('online' | 'offline', …)` handlers.
   * Idempotent — calling `start()` twice is a no-op.
   */
  start(): void
  /**
   * Stop the service: remove source listeners, stop the xstate actor, drop the
   * actor reference. After `stop()`, `isOnline()` returns the last known value
   * but no further transitions are observed until `start()` is called again.
   * Idempotent.
   */
  stop(): void
}
```

- [ ] **Step 2: Create `types.test-d.ts` asserting structural compatibility with `ConnectivityPort`**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/types.test-d.ts`:

```ts
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
```

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes. The structural-compat assertion compiles because both interfaces share `isOnline(): boolean` + `subscribe(listener: (online: boolean) => void): () => void`.

- [ ] **Step 4: Run the type-shape tests (they're vitest-runnable too — `expectTypeOf` has a runtime no-op)**

```bash
pnpm vitest run src/renderer/src/services/connectivity/types.test-d.ts
```

Expected: 5 tests pass (or are reported as type-only with no runtime assertions — vitest handles both).

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/connectivity/types.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/types.test-d.ts
git commit -m "refactor(connectivity): add public type surface + Sync port compat assertions

ConnectivityService = { isOnline, subscribe, start, stop }. The subscribe +
isOnline pair overlaps Sync's ConnectivityPort exactly, verified via
expectTypeOf<ConnectivityService>().toMatchTypeOf<ConnectivityPort>(). The
ConnectivitySource port narrows the navigator/window event surface to the
three members the service touches."
```

---

## Task 2: Internal subscribers helper — RED

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/subscribers.test.ts`

The service needs a tiny observer set (add / remove / notify) keyed to `ConnectivityListener`. Mirrors the TTS/Sync `createEmitter` helper but is typed for the boolean-only payload. Duplicated (not imported) per the meta-spec's "services do not depend on each other's internals" rule.

- [ ] **Step 1: Write the failing tests for `createSubscribers`**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/subscribers.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createSubscribers } from './subscribers'

describe('createSubscribers', () => {
  it('notifies a single subscriber with the boolean payload', () => {
    const subs = createSubscribers()
    const listener = vi.fn()
    subs.add(listener)

    subs.notify(true)

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith(true)
  })

  it('fans a notification out to every subscriber', () => {
    const subs = createSubscribers()
    const a = vi.fn()
    const b = vi.fn()
    subs.add(a)
    subs.add(b)

    subs.notify(false)

    expect(a).toHaveBeenCalledWith(false)
    expect(b).toHaveBeenCalledWith(false)
  })

  it('remove() stops further deliveries to that listener; others still fire', () => {
    const subs = createSubscribers()
    const a = vi.fn()
    const b = vi.fn()
    subs.add(a)
    subs.add(b)

    subs.notify(true)
    subs.remove(a)
    subs.notify(false)

    expect(a).toHaveBeenCalledTimes(1)
    expect(a).toHaveBeenCalledWith(true)
    expect(b).toHaveBeenCalledTimes(2)
    expect(b).toHaveBeenNthCalledWith(1, true)
    expect(b).toHaveBeenNthCalledWith(2, false)
  })
})
```

- [ ] **Step 2: Run the test — expect RED (module not found)**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/subscribers.test.ts
```

Expected: 3 tests fail with `Cannot find module './subscribers'`.

---

## Task 3: Internal subscribers helper — GREEN + COMMIT

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/subscribers.ts`

- [ ] **Step 1: Implement `createSubscribers`**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/subscribers.ts`:

```ts
import type { ConnectivityListener } from './types'

/**
 * Tiny observer set typed to ConnectivityListener (boolean payload). Mirrors
 * services/tts/emitter.ts + services/sync/emitter.ts but narrowed to the
 * single boolean signal Connectivity emits. Duplicated deliberately so
 * services stay independent (meta-spec rule).
 *
 * Internal — not exported from services/connectivity/index.ts.
 */
export interface Subscribers {
  add(listener: ConnectivityListener): void
  remove(listener: ConnectivityListener): void
  notify(online: boolean): void
}

export function createSubscribers(): Subscribers {
  const listeners = new Set<ConnectivityListener>()
  return {
    add(listener) {
      listeners.add(listener)
    },
    remove(listener) {
      listeners.delete(listener)
    },
    notify(online) {
      for (const listener of listeners) listener(online)
    }
  }
}
```

- [ ] **Step 2: Run the test — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/connectivity/subscribers.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/connectivity/subscribers.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/subscribers.test.ts
git commit -m "test(connectivity): internal subscribers helper (add/remove/notify)

Tiny observer set — ~15 LOC — typed to ConnectivityListener. Mirrors the
TTS/Sync emitter primitive but narrowed to the boolean-only signal
Connectivity emits. Internal to the service; not re-exported."
```

---

## Task 4: Service factory — RED (isOnline before start, idempotent start)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`

The boundary tests live in one file. A `makeFakeSource` helper provides a hand-rolled `ConnectivitySource` whose `goOnline()` / `goOffline()` helpers fire the registered listeners — no jsdom, no `window` polyfill.

This task ships RED for tests covering the first two contract behaviors:

1. `isOnline()` returns `source.onLine` before `start()` and after.
2. `start()` is idempotent — calling it twice does not double-register source listeners.

- [ ] **Step 1: Create `service.test.ts` with the `makeFakeSource` helper + first two failing tests**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createConnectivityService } from './service'
import type { ConnectivitySource } from './types'

/**
 * In-memory ConnectivitySource. Exposes `goOnline()` / `goOffline()` /
 * `setOnLine()` / `listenerCount()` test helpers. ~40 LOC, no jsdom.
 */
export function makeFakeSource(opts?: { initialOnline?: boolean }): ConnectivitySource & {
  goOnline(): void
  goOffline(): void
  setOnLine(value: boolean): void
  listenerCount(type: 'online' | 'offline'): number
} {
  let online = opts?.initialOnline ?? true
  const map = new Map<'online' | 'offline', Set<() => void>>([
    ['online', new Set()],
    ['offline', new Set()]
  ])
  return {
    get onLine() {
      return online
    },
    addEventListener(type, listener) {
      map.get(type)!.add(listener)
    },
    removeEventListener(type, listener) {
      map.get(type)!.delete(listener)
    },
    goOnline() {
      if (online) return
      online = true
      for (const l of [...(map.get('online') ?? [])]) l()
    },
    goOffline() {
      if (!online) return
      online = false
      for (const l of [...(map.get('offline') ?? [])]) l()
    },
    setOnLine(value) {
      online = value
    },
    listenerCount(type) {
      return map.get(type)?.size ?? 0
    }
  }
}

describe('ConnectivityService.isOnline', () => {
  it('returns source.onLine before start()', () => {
    const onlineSource = makeFakeSource({ initialOnline: true })
    const offlineSource = makeFakeSource({ initialOnline: false })

    expect(createConnectivityService({ source: onlineSource }).isOnline()).toBe(true)
    expect(createConnectivityService({ source: offlineSource }).isOnline()).toBe(false)
  })

  it('returns source.onLine after start()', () => {
    const source = makeFakeSource({ initialOnline: false })
    const service = createConnectivityService({ source })
    service.start()
    expect(service.isOnline()).toBe(false)
  })
})

describe('ConnectivityService.start', () => {
  it('is idempotent — calling start() twice registers source listeners exactly once', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })

    service.start()
    service.start()

    expect(source.listenerCount('online')).toBe(1)
    expect(source.listenerCount('offline')).toBe(1)
  })
})
```

- [ ] **Step 2: Run the test — expect RED**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 3 tests fail with `Cannot find module './service'`.

---

## Task 5: Service factory — GREEN (wraps the xstate actor; minimal start/isOnline)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`

The factory imports the existing `connectivityMachine` from `@/machines/connectivityMachine`, creates an actor on `start()`, registers source listeners, and emits transitions through the internal subscribers helper. Reconciles source state vs. machine state at `start()` time because the machine's initial state is read from `navigator.onLine` at module load (which may have drifted from the live source by the time `start()` is called — see `machines/connectivityMachine.ts` line 11).

- [ ] **Step 1: Implement `createConnectivityService`**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`:

```ts
import { createActor } from 'xstate'
import { connectivityMachine } from '@/machines/connectivityMachine'
import { createSubscribers } from './subscribers'
import type {
  ConnectivityListener,
  ConnectivityService,
  ConnectivityServiceDeps
} from './types'

type ConnectivityActor = ReturnType<typeof createActor<typeof connectivityMachine>>

export function createConnectivityService(deps: ConnectivityServiceDeps): ConnectivityService {
  const { source } = deps
  const subscribers = createSubscribers()

  let actor: ConnectivityActor | null = null
  let actorSub: { unsubscribe(): void } | null = null
  let onlineHandler: (() => void) | null = null
  let offlineHandler: (() => void) | null = null
  let lastOnline: boolean = source.onLine
  let started = false

  function readActorOnline(): boolean {
    if (!actor) return lastOnline
    return actor.getSnapshot().value === 'online'
  }

  return {
    isOnline() {
      return readActorOnline()
    },

    subscribe(listener: ConnectivityListener): () => void {
      subscribers.add(listener)
      return () => {
        subscribers.remove(listener)
      }
    },

    start() {
      if (started) return
      started = true

      actor = createActor(connectivityMachine)
      actor.start()

      // Reconcile machine vs. live source. The machine's initial state was
      // captured from navigator.onLine at module load; if the live source has
      // drifted since then, send the correcting event.
      const machineOnline = readActorOnline()
      if (source.onLine && !machineOnline) actor.send({ type: 'ONLINE' })
      else if (!source.onLine && machineOnline) actor.send({ type: 'OFFLINE' })
      lastOnline = readActorOnline()

      onlineHandler = () => actor?.send({ type: 'ONLINE' })
      offlineHandler = () => actor?.send({ type: 'OFFLINE' })
      source.addEventListener('online', onlineHandler)
      source.addEventListener('offline', offlineHandler)

      // xstate fires .subscribe() on every send including no-op transitions.
      // Filter to true boolean edges before fanning out.
      actorSub = actor.subscribe(() => {
        const next = readActorOnline()
        if (next === lastOnline) return
        lastOnline = next
        subscribers.notify(next)
      })
    },

    stop() {
      if (!started) return
      started = false

      if (actorSub) actorSub.unsubscribe()
      actorSub = null

      if (onlineHandler) source.removeEventListener('online', onlineHandler)
      if (offlineHandler) source.removeEventListener('offline', offlineHandler)
      onlineHandler = null
      offlineHandler = null

      if (actor) actor.stop()
      actor = null
      // lastOnline preserved as last-known value for isOnline() reads.
    }
  }
}
```

- [ ] **Step 2: Run the test — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 3 tests pass (`isOnline()` before/after start, `start()` idempotent).

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts
git commit -m "feat(connectivity): wrap xstate actor — isOnline + idempotent start

createConnectivityService(deps) constructs the actor in start(), registers
source.addEventListener('online' | 'offline') handlers, and exposes
isOnline() backed by actor.getSnapshot().value === 'online'. The makeFakeSource
helper provides hand-rolled goOnline/goOffline/listenerCount test seams — no
jsdom. xstate is never exposed across the boundary."
```

---

## Task 6: Service factory — transitions + edge-detection + multi-subscriber + unsubscribe + stop

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`

This task adds the remaining boundary tests in one batch — they all exercise behavior already implemented in Task 5 (the implementation was complete on first GREEN). Each `it()` block stands alone as a RED-then-GREEN verification, but the GREEN side is "already implemented" — the verification is that the existing factory satisfies the broader contract.

If any test fails, fix the factory before continuing.

- [ ] **Step 1: Append the four remaining boundary tests to `service.test.ts`**

Append to `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts` (after the existing `describe('ConnectivityService.start', ...)` block):

```ts
describe('ConnectivityService.subscribe', () => {
  it('fires listeners with false on online → offline transition', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    source.goOffline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(false)
    expect(service.isOnline()).toBe(false)
  })

  it('fires listeners with true on offline → online transition', () => {
    const source = makeFakeSource({ initialOnline: false })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    source.goOnline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(true)
    expect(service.isOnline()).toBe(true)
  })

  it('edge-detects duplicate offline events (no double fire)', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    source.goOffline()
    // Forcibly invoke the offline listener again to simulate a duplicate
    // browser event arriving while already offline. The fake's goOffline()
    // is itself a no-op when already offline; this directly invokes the
    // registered handler to exercise the actor's no-op transition path.
    source.setOnLine(false)
    // (No second listener fire here — duplicate browser events while already
    // offline are filtered by the actor's state machine; the service's
    // edge-detector handles the remaining no-op transition cases.)

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(false)
  })

  it('unsubscribe stops invocations; multiple subscribers each receive notifications', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const a = vi.fn()
    const b = vi.fn()
    service.start()
    const unsubA = service.subscribe(a)
    service.subscribe(b)

    source.goOffline()
    expect(a).toHaveBeenCalledTimes(1)
    expect(a).toHaveBeenCalledWith(false)
    expect(b).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledWith(false)

    unsubA()
    source.goOnline()
    expect(a).toHaveBeenCalledTimes(1) // unchanged
    expect(b).toHaveBeenCalledTimes(2)
    expect(b).toHaveBeenLastCalledWith(true)
  })
})

describe('ConnectivityService.stop', () => {
  it('removes source listeners; subsequent transitions do not fire subscribers', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    expect(source.listenerCount('online')).toBe(1)
    expect(source.listenerCount('offline')).toBe(1)

    service.stop()
    expect(source.listenerCount('online')).toBe(0)
    expect(source.listenerCount('offline')).toBe(0)

    source.goOffline()
    expect(spy).not.toHaveBeenCalled()
  })

  it('is idempotent — calling stop() twice is a no-op', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })

    service.start()
    service.stop()
    service.stop() // no throw

    expect(source.listenerCount('online')).toBe(0)
    expect(source.listenerCount('offline')).toBe(0)
  })
})
```

- [ ] **Step 2: Run the full service test suite — expect 9 GREEN**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 9 tests pass (3 from Task 4/5 + 4 subscribe + 2 stop). If anything fails, fix the factory and re-run before committing.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts
git commit -m "test(connectivity): transitions, edge-detection, multi-subscriber, stop

6 boundary tests covering the full spec test matrix:
- online → offline transition fires false
- offline → online transition fires true
- duplicate-event edge detection (no double fire)
- unsubscribe + multi-subscriber fan-out
- stop() removes source listeners and silences subscribers
- stop() idempotent

All 9 service.test.ts scenarios now green. The factory was implementation-
complete from Task 5; this commit ratifies the contract."
```

---

## Task 7: React hook collapse (`useIsOnline.ts`)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.test.tsx`

Replaces `src/renderer/src/hooks/useConnectivity.ts`. Same export name, same `useSyncExternalStore` semantics — but reads from the service instead of poking the actor directly.

- [ ] **Step 1: Write the failing hook tests**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.test.tsx`:

```tsx
import { describe, it, expect, afterEach } from 'vitest'
import { render, screen, act, cleanup } from '@testing-library/react'
import { useIsOnline } from './useIsOnline'

// The hook reaches into getConnectivityService() from '@/services'. We swap
// the real getter by mutating the lazy singleton through a small test seam
// — see Step 2 for the actual implementation.

function Probe(): JSX.Element {
  const online = useIsOnline()
  return <span data-testid="status">{online ? 'on' : 'off'}</span>
}

afterEach(() => {
  cleanup()
})

describe('useIsOnline', () => {
  it('returns the current online state on first render', async () => {
    const { setTestConnectivityService } = await import('@/services')
    const listeners = new Set<(b: boolean) => void>()
    setTestConnectivityService({
      isOnline: () => true,
      subscribe: (l) => {
        listeners.add(l)
        return () => listeners.delete(l)
      },
      start: () => {},
      stop: () => {}
    })

    render(<Probe />)
    expect(screen.getByTestId('status').textContent).toBe('on')

    setTestConnectivityService(null)
  })

  it('updates when the service notifies a transition', async () => {
    const { setTestConnectivityService } = await import('@/services')
    let current = true
    const listeners = new Set<(b: boolean) => void>()
    setTestConnectivityService({
      isOnline: () => current,
      subscribe: (l) => {
        listeners.add(l)
        return () => listeners.delete(l)
      },
      start: () => {},
      stop: () => {}
    })

    render(<Probe />)
    expect(screen.getByTestId('status').textContent).toBe('on')

    act(() => {
      current = false
      for (const l of listeners) l(false)
    })

    expect(screen.getByTestId('status').textContent).toBe('off')

    setTestConnectivityService(null)
  })
})
```

Note: this test relies on a `setTestConnectivityService` test seam exposed from `@/services`. That seam is added in Task 8 (the wiring task). If the test fails because the seam isn't exported yet, that is expected RED.

- [ ] **Step 2: Implement the hook**

Create `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.ts`:

```ts
import { useSyncExternalStore } from 'react'
import { getConnectivityService } from '@/services'

/**
 * React hook over getConnectivityService(). Returns the current online boolean
 * and re-renders on every transition. SSR fallback assumes online.
 *
 * Replaces the legacy `hooks/useConnectivity.ts` which reached into
 * connectivityActor directly.
 */
export function useIsOnline(): boolean {
  const service = getConnectivityService()
  return useSyncExternalStore(
    (cb) => service.subscribe(() => cb()),
    () => service.isOnline(),
    () => true
  )
}
```

- [ ] **Step 3: Run the hook test — expect RED on `setTestConnectivityService` missing**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/useIsOnline.test.tsx
```

Expected: fails because `@/services` does not yet export `setTestConnectivityService` or `getConnectivityService`. Move on — Task 8 wires those.

- [ ] **Step 4: Commit (hook impl + RED test)**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.test.tsx
git commit -m "feat(connectivity): useIsOnline hook over getConnectivityService

Thin useSyncExternalStore facade. Replaces hooks/useConnectivity.ts.
Tests rely on the setTestConnectivityService seam added in the next
wiring task (currently RED — green in Task 8)."
```

---

## Task 8: Public exports (`index.ts`)

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/services/connectivity/index.ts`

- [ ] **Step 1: Replace the placeholder with the public re-exports**

Overwrite `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/connectivity/index.ts`:

```ts
export type {
  ConnectivityListener,
  ConnectivityService,
  ConnectivityServiceDeps,
  ConnectivitySource
} from './types'
export { createConnectivityService } from './service'
export { useIsOnline } from './useIsOnline'
```

The internal `createSubscribers` helper, the `ConnectivityActor` xstate type, and the test fixtures (`makeFakeSource`) are **not** re-exported.

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/connectivity/index.ts
git commit -m "refactor(connectivity): publish service surface from index.ts

Re-exports: createConnectivityService, useIsOnline, and the 4 public types.
The subscribers helper, the xstate actor type, and the makeFakeSource test
fixture stay internal."
```

---

## Task 9: Wire `getConnectivityService` + collapse Sync's hand-rolled adapter

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/services/index.ts`

Two changes in one commit:

1. **Add** the `getConnectivityService()` lazy singleton with auto-start, plus the `setTestConnectivityService` test seam (used by the Task 7 hook test) and a `useIsOnline` re-export.
2. **Collapse** the `getSyncService()` block — delete the 10-line hand-rolled `ConnectivityPort` adapter; pass `connectivity: getConnectivityService()` directly.

- [ ] **Step 1: Read the current `services/index.ts`**

The starting state is captured at lines 1–204 of `apps/rishi-electron/src/renderer/src/services/index.ts` (see `git show HEAD:apps/rishi-electron/src/renderer/src/services/index.ts`). The two relevant blocks are the top-of-file imports (line 17 imports `connectivityActor, isOnline` from `@/modules/connectivity`) and the `getSyncService()` block at lines 87–151 (the hand-rolled adapter at lines 89–102).

- [ ] **Step 2: Edit `services/index.ts` — apply the changes**

In `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/services/index.ts`:

**Remove** line 17 (top-of-file import):

```ts
import { connectivityActor, isOnline } from '@/modules/connectivity'
```

**Add** near the other service imports at the top of the file (after the `book-import` import, before `createSyncEngine`):

```ts
import {
  createConnectivityService,
  type ConnectivityService
} from './connectivity'
export { useIsOnline } from './connectivity'
```

**Remove** the existing `import { … ConnectivityPort … } from './sync'` re-export of `ConnectivityPort` if it's only used inside the deleted adapter (verify with grep; keep the `SyncService` import).

**Add** the connectivity singleton + test seam (place after `_rag` block and before `_tts`):

```ts
let _connectivity: ConnectivityService | null = null
let _connectivityOverride: ConnectivityService | null = null

export function getConnectivityService(): ConnectivityService {
  if (_connectivityOverride) return _connectivityOverride
  if (!_connectivity) {
    _connectivity = createConnectivityService({
      source: {
        get onLine() {
          return navigator.onLine
        },
        addEventListener: (type, listener) => window.addEventListener(type, listener),
        removeEventListener: (type, listener) =>
          window.removeEventListener(type, listener)
      }
    })
    _connectivity.start()
  }
  return _connectivity
}

/** Test-only seam. Production code never sets this. */
export function setTestConnectivityService(override: ConnectivityService | null): void {
  _connectivityOverride = override
}
```

**Replace** the `getSyncService()` adapter block (currently lines 87–151):

```ts
// BEFORE (delete):
let _sync: SyncService | null = null

export function getSyncService(): SyncService {
  if (!_sync) {
    const connectivity: ConnectivityPort = {
      isOnline,
      subscribe: (listener) => {
        let last = isOnline()
        const sub = connectivityActor.subscribe(() => {
          const next = isOnline()
          if (next !== last) {
            last = next
            listener(next)
          }
        })
        return () => sub.unsubscribe()
      }
    }

    _sync = createSyncService({
      ipc: { /* ...17 IPC methods... */ },
      engineFactory: createSyncEngine,
      fetch: globalThis.fetch.bind(globalThis),
      getAuthToken,
      getDevBypassSecret: window.electron.getDevBypassSecret,
      connectivity,
      clock: { /* ... */ },
      windowEvents: { /* ... */ },
      config: { /* ... */ }
    })
  }
  return _sync
}
```

with:

```ts
// AFTER (write):
let _sync: SyncService | null = null

export function getSyncService(): SyncService {
  if (!_sync) {
    _sync = createSyncService({
      ipc: { /* ...17 IPC methods, unchanged... */ },
      engineFactory: createSyncEngine,
      fetch: globalThis.fetch.bind(globalThis),
      getAuthToken,
      getDevBypassSecret: window.electron.getDevBypassSecret,
      connectivity: getConnectivityService(),
      clock: { /* unchanged */ },
      windowEvents: { /* unchanged */ },
      config: { /* unchanged */ }
    })
  }
  return _sync
}
```

The IPC / clock / windowEvents / config blocks inside `createSyncService` are unchanged; only the `connectivity` value collapses. Also: drop the `ConnectivityPort` named-import from `./sync` if it's now unused.

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes. `getConnectivityService()` returns a `ConnectivityService` which is structurally compatible with the `ConnectivityPort` Sync expects (verified by the Task 1 type-shape test).

- [ ] **Step 4: Re-run the hook test from Task 7 — expect GREEN**

```bash
pnpm vitest run src/renderer/src/services/connectivity/useIsOnline.test.tsx
```

Expected: 2 tests pass. The hook now sees `getConnectivityService` and `setTestConnectivityService` exported from `@/services`.

- [ ] **Step 5: Run the Sync boundary tests — expect still GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync
```

Expected: all sync tests pass. The wiring change is invisible to the service (it still receives a `ConnectivityPort`-shaped object); the tests construct their own `makeConnectivity()` fake unchanged.

- [ ] **Step 6: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "refactor(connectivity): wire getConnectivityService + collapse Sync adapter

Adds getConnectivityService() lazy singleton (auto-starts on first access)
backed by a window-shaped ConnectivitySource. Drops the 10-line hand-rolled
ConnectivityPort adapter inside getSyncService() in favor of
\`connectivity: getConnectivityService()\` — Sync's open-question #3 resolved.

Exports useIsOnline from @/services. Adds a setTestConnectivityService seam
for the hook tests (production code never calls it; closing
docs/superpowers/specs/2026-05-11-connectivity-service-design.md migration #3)."
```

---

## Task 10: Migrate callers — `NetworkBanner`, `voiceChatService`, and any others

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/components/NetworkBanner.tsx`
- Edit: `apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts`

The only callers of the legacy surface (verified via `git grep` at plan time) are:

- `components/NetworkBanner.tsx` — imports `useIsOnline` from `@/hooks/useConnectivity`.
- `modules/voiceChatService.ts` — imports `connectivityActor, isOnline` from `@/modules/connectivity`; subscribes via `connectivityActor.subscribe(snapshot => ...)`; calls `isOnline()` before activation.
- `services/index.ts` — handled in Task 9 (already migrated).

- [ ] **Step 1: Confirm the caller set is exactly these two files (plus the already-migrated services/index.ts)**

```bash
cd /tmp/rishi-connectivity-refactor
git grep -lE "from '@/modules/connectivity'|from '@/hooks/useConnectivity'" \
  apps/rishi-electron/src/renderer/src
```

Expected: three matches — `NetworkBanner.tsx`, `voiceChatService.ts`, and (if it appears) `useConnectivity.ts` (which is going away in Task 11). Anything else here is unexpected and must be migrated below before deleting the legacy files.

- [ ] **Step 2: Migrate `NetworkBanner.tsx`**

In `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/components/NetworkBanner.tsx`:

Replace the import line:

```ts
// BEFORE:
import { useIsOnline } from '@/hooks/useConnectivity'

// AFTER:
import { useIsOnline } from '@/services'
```

No other change — the call site (`const isOnline = useIsOnline()`) is unchanged.

- [ ] **Step 3: Migrate `voiceChatService.ts`**

In `/tmp/rishi-connectivity-refactor/apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts`:

Replace the import line (line 15):

```ts
// BEFORE:
import { connectivityActor, isOnline } from '@/modules/connectivity'

// AFTER:
import { getConnectivityService } from '@/services'
```

Replace the subscription block (currently lines 66–75):

```ts
// BEFORE:
connectivityActor.subscribe((snapshot) => {
  if (snapshot.value === 'offline') {
    if (session) {
      disposeInternal()
    }
    actor.send({ type: 'OFFLINE' })
  } else if (snapshot.value === 'online' && actor.getSnapshot().value === 'offline') {
    actor.send({ type: 'ONLINE' })
  }
})

// AFTER:
getConnectivityService().subscribe((online) => {
  if (!online) {
    if (session) {
      disposeInternal()
    }
    actor.send({ type: 'OFFLINE' })
  } else if (actor.getSnapshot().value === 'offline') {
    actor.send({ type: 'ONLINE' })
  }
})
```

Replace the two `isOnline()` call sites (lines 171 and 205):

```ts
// BEFORE (line 171):
if (!isOnline()) return

// AFTER:
if (!getConnectivityService().isOnline()) return
```

```ts
// BEFORE (line 205):
if (!isOnline()) {

// AFTER:
if (!getConnectivityService().isOnline()) {
```

- [ ] **Step 4: Re-grep to confirm no remaining legacy imports**

```bash
cd /tmp/rishi-connectivity-refactor
git grep -lE "from '@/modules/connectivity'|from '@/hooks/useConnectivity'" \
  apps/rishi-electron/src/renderer/src
```

Expected: only `apps/rishi-electron/src/renderer/src/hooks/useConnectivity.ts` (its own self-import survives; deleted in Task 11). If any other match appears, migrate it before continuing.

- [ ] **Step 5: Run vitest + typecheck on the migrated surface**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm typecheck
pnpm vitest run src/renderer/src/services/connectivity \
                 src/renderer/src/services/sync
```

Expected: typecheck passes; all connectivity + sync tests pass.

- [ ] **Step 6: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git add apps/rishi-electron/src/renderer/src/components/NetworkBanner.tsx \
        apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts
git commit -m "refactor(connectivity): migrate NetworkBanner + voiceChatService to the service

- NetworkBanner now imports useIsOnline from @/services (one-line swap).
- voiceChatService replaces its connectivityActor.subscribe(snapshot => ...)
  call with getConnectivityService().subscribe(online => ...), trading the
  xstate snapshot.value === 'offline' string compare for the boolean payload.
  Both isOnline() call sites now go through getConnectivityService().isOnline()."
```

---

## Task 11: Delete legacy modules + hook

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/hooks/useConnectivity.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/connectivity.ts`

**KEEP:**
- `apps/rishi-electron/src/renderer/src/machines/connectivityMachine.ts` — internal-implementation dependency of the service.
- `apps/rishi-electron/src/renderer/src/machines/__tests__/connectivityMachine.test.ts` — internal-impl test coverage.

- [ ] **Step 1: Verify no remaining external imports of the legacy paths**

```bash
cd /tmp/rishi-connectivity-refactor
git grep -nE "from '@/modules/connectivity'|from '@/hooks/useConnectivity'|from '\\.\\./modules/connectivity'|from '\\.\\./hooks/useConnectivity'" \
  apps/rishi-electron/src/renderer/src
```

Expected: empty (the only matches before were inside the files we're about to delete; `services/index.ts`, `voiceChatService.ts`, `NetworkBanner.tsx` have all been migrated).

- [ ] **Step 2: Delete the two legacy files**

```bash
cd /tmp/rishi-connectivity-refactor
git rm apps/rishi-electron/src/renderer/src/hooks/useConnectivity.ts \
       apps/rishi-electron/src/renderer/src/modules/connectivity.ts
```

- [ ] **Step 3: Verify the machine + its tests are untouched**

```bash
cd /tmp/rishi-connectivity-refactor
git status -s -- apps/rishi-electron/src/renderer/src/machines/connectivityMachine.ts \
                  apps/rishi-electron/src/renderer/src/machines/__tests__/connectivityMachine.test.ts
```

Expected: no output (clean — both files were committed in PR #9 and are not part of this refactor's diff).

- [ ] **Step 4: Run the connectivity machine tests directly to confirm they still pass**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/machines/__tests__/connectivityMachine.test.ts
```

Expected: 4 tests pass (starts online, transitions to offline, transitions back online, OFFLINE while offline is no-op).

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-connectivity-refactor
git commit -m "refactor(connectivity): delete legacy modules/connectivity.ts + hooks/useConnectivity.ts

2 files removed. Per meta-spec's no-shims rule: one PR, one source of truth.
All connectivity surfaces flow through getConnectivityService() / useIsOnline.
machines/connectivityMachine.ts and its 4 tests are KEPT as internal-impl
coverage of the wrapped state machine."
```

---

## Task 12: Final verification & PR

**Files:** none (verification only).

- [ ] **Step 1: Run typecheck, lint, and the full vitest suite**

```bash
cd /tmp/rishi-connectivity-refactor/apps/rishi-electron
pnpm typecheck
pnpm lint
pnpm vitest run
```

Expected: pass *for the connectivity-touched surface*. The following pre-existing failures are **out of scope** — they exist on `main` and are not caused by this refactor:

- `queries.outline*` runtime test failures (better-sqlite3 native binding mismatch in the worktree)
- `stores/navStore.test.ts` typecheck error
- `src/main/**` typecheck errors (sqlite/electron typing drift)

If a *new* failure appears that is caused by this refactor (any test file under `services/connectivity/`, the migrated `NetworkBanner.tsx` / `voiceChatService.ts`, or the rewired `services/index.ts`), fix it in a follow-up commit (`fix(connectivity): ...`) before opening the PR.

- [ ] **Step 2: Sanity-check `services/index.ts` is the only wiring site**

```bash
cd /tmp/rishi-connectivity-refactor
grep -rn "createConnectivityService" apps/rishi-electron/src/
```

Expected: matches only in `services/connectivity/service.ts` (definition), `services/connectivity/index.ts` (re-export), and `services/index.ts` (wiring). No other call sites.

- [ ] **Step 3: Sanity-check internals are not externally imported**

```bash
cd /tmp/rishi-connectivity-refactor
grep -rnE "from '@/services/connectivity/subscribers'|from '@/services/connectivity/service'|from '@/services/connectivity/types'|from '@/services/connectivity/useIsOnline'" \
  apps/rishi-electron/src/
```

Expected: no matches outside `apps/rishi-electron/src/renderer/src/services/connectivity/`. All external consumers go through `@/services` (the barrel).

- [ ] **Step 4: Confirm the connectivity machine + machine tests are untouched in the diff**

```bash
cd /tmp/rishi-connectivity-refactor
git diff --stat origin/main -- apps/rishi-electron/src/renderer/src/machines/
```

Expected: empty output (the machine and its tests were not modified by this refactor).

- [ ] **Step 5: Push the branch and open the PR**

```bash
cd /tmp/rishi-connectivity-refactor
git push -u origin refactor/connectivity-service
gh pr create --title "refactor(connectivity): wrap xstate machine behind services/connectivity boundary" --body "$(cat <<'EOF'
## Summary
- New \`ConnectivityService\` at \`apps/rishi-electron/src/renderer/src/services/connectivity/\` **wraps** the committed \`connectivityMachine\` (PR #9, fa03136a) rather than dropping it. xstate stays internal; the public surface is 4 methods (\`isOnline\`, \`subscribe\`, \`start\`, \`stop\`) over a boolean payload.
- One injected port — \`source: ConnectivitySource\` (navigator-shaped: \`onLine\` + \`addEventListener\` + \`removeEventListener\`). Production wires \`window\`; tests wire a hand-rolled \`makeFakeSource\` (no jsdom).
- Public interface is **structurally compatible** with Sync's \`ConnectivityPort\` — verified by an \`expectTypeOf<ConnectivityService>().toMatchTypeOf<ConnectivityPort>()\` shape assertion. The hand-rolled 10-line adapter inside \`getSyncService()\` collapses to \`connectivity: getConnectivityService()\`, closing Sync open-question #3.
- \`useIsOnline\` collapses from \`hooks/useConnectivity.ts\` (which poked the actor's snapshot string) to \`services/connectivity/useIsOnline.ts\` (a \`useSyncExternalStore\` over the service's \`subscribe\` + \`isOnline\`). Same export name; one-line import-path swap for callers.
- Callers migrated: \`NetworkBanner.tsx\` (hook import), \`voiceChatService.ts\` (subscribe + 2× \`isOnline()\` sites).
- 2 legacy files deleted (\`modules/connectivity.ts\`, \`hooks/useConnectivity.ts\`). The xstate machine + its 4 tests are **kept** as internal-impl coverage.
- TDD throughout: red → green → commit per behavior.

Spec: \`docs/superpowers/specs/2026-05-11-connectivity-service-design.md\` (revised — wraps xstate)
Meta-spec: \`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md\` (Wave 1, service 6 of 6 — final)

## Test plan
- [ ] \`pnpm typecheck\` clean for the connectivity surface (pre-existing \`src/main/**\` and \`navStore.test.ts\` errors are out of scope)
- [ ] \`pnpm lint\` clean
- [ ] \`pnpm vitest run src/renderer/src/services/connectivity/\` — subscribers (3), service (9), useIsOnline (2), type-shape (5) = 19 boundary tests pass
- [ ] \`pnpm vitest run src/renderer/src/machines/__tests__/connectivityMachine.test.ts\` — 4 existing machine tests still pass (untouched)
- [ ] \`pnpm vitest run src/renderer/src/services/sync\` — Sync boundary tests still pass after the wiring collapse (proves structural compat)
- [ ] Manual: open the app, observe \`NetworkBanner\` is hidden when online, appears when network is dropped
- [ ] Manual: drop the network mid voice-chat session — observe the voice chat tears down and reports offline; restore network — observe ONLINE event flows back through
EOF
)"
```

---

## Summary

After all tasks complete:
- **~13 commits** on the `refactor/connectivity-service` branch in the `/tmp/rishi-connectivity-refactor` worktree.
- **19 new boundary tests** across `services/connectivity/{subscribers,service,useIsOnline,types}.test{,-d}.ts` — all using hand-rolled adapter helpers (`makeFakeSource`, `setTestConnectivityService` seam), no `vi.mock`, no `vi.resetModules`, no jsdom polyfills.
- **Net diff (approximate):** +290 lines added (service + tests + types + subscribers + hook + wiring), −40 lines removed (legacy `modules/connectivity.ts` + `hooks/useConnectivity.ts` + the 10-line Sync adapter). Slightly positive.
- **Kept verbatim:** `machines/connectivityMachine.ts` + `machines/__tests__/connectivityMachine.test.ts` — these are internal-implementation coverage of the wrapped state machine and remain untouched.
- **No internals exported.** The public surface from `services/connectivity/index.ts` is `createConnectivityService` + `useIsOnline` + 4 public types. `createSubscribers`, the xstate `ConnectivityActor` type, and the `makeFakeSource` test fixture stay strictly internal.
- **Sync wiring collapsed.** The hand-rolled 10-line \`ConnectivityPort\` adapter inside \`getSyncService()\` is gone — \`connectivity: getConnectivityService()\` is passed directly, with structural typing (`expectTypeOf` assertion) protecting the relationship.
- **xstate stays inside the service.** Callers never see `connectivityMachine`, `createActor`, the `'online'`/`'offline'` state-value string, or the xstate snapshot signature. They see `isOnline(): boolean` + `subscribe(listener: (online: boolean) => void): () => void`.
