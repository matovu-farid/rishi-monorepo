# Connectivity service — design

**Status:** revised 2026-05-11 — wraps committed xstate machine
**Parent:** [`2026-05-11-services-and-effect-adoption-design.md`](./2026-05-11-services-and-effect-adoption-design.md) (meta-spec)
**Scope:** Wave 1, service #2 of 6 (final service of Wave 1). Stage 1 only (plain TypeScript wrapping a small xstate machine). `apps/rishi-electron` renderer-side service that owns "are we online right now?" as a single source of truth.

## Revision history

- **2026-05-11 (revised).** Previous version dropped xstate; current version **wraps** the xstate `connectivityMachine` committed in PR #9 (`fa03136a`). The user pre-committed the machine + hook + module + banner, indicating they want xstate's explicit state semantics for connectivity. The service hides xstate behind the boundary; callers see a plain `boolean` + `subscribe`.
- **2026-05-11 (original).** Initial draft. Proposed a plain-TS observer-pattern service that replaced the xstate machine wholesale. Superseded by this revision.

## Goal

Collapse the current renderer-side connectivity surface (`modules/connectivity.ts` actor + `machines/connectivityMachine.ts` xstate machine + `hooks/useConnectivity.ts` React hook) into one cohesive renderer-side service exposed through a small, typed interface that matches the `ConnectivityPort` shape the Sync service already consumes. The xstate machine **stays** as an internal implementation detail — callers never see `connectivityActor`, `connectivityMachine`, or the `'online' | 'offline'` state-value string. They see `isOnline(): boolean` and `subscribe(listener): () => void`.

## Background

Connectivity today is spread across four renderer-side files all committed in PR #9 (`fa03136a`):

- **`src/renderer/src/machines/connectivityMachine.ts`** — a 16-line xstate machine with 2 states (`'online'`, `'offline'`), 2 events (`'ONLINE'`, `'OFFLINE'`), zero context. Initial state is read from `navigator.onLine` once at module-load.
- **`src/renderer/src/modules/connectivity.ts`** — creates the actor, starts it, registers two `window.addEventListener('online' | 'offline', …)` handlers at module-load time, and exports `connectivityActor` + a derived `isOnline()` helper that pulls `snapshot.value === 'online'`.
- **`src/renderer/src/hooks/useConnectivity.ts`** — a `useSyncExternalStore` adapter on top of `connectivityActor.subscribe` + `snapshot.value`.
- **`src/renderer/src/components/NetworkBanner.tsx`** — renders an offline banner; consumes the hook.
- **`src/renderer/src/machines/__tests__/connectivityMachine.test.ts`** — 4 tests over the machine, no integration with browser events.

The Sync service (already in production, see `services/sync/service.ts` and `services/index.ts`) defines a port:

```ts
// services/sync/types.ts (excerpt)
export interface ConnectivityPort {
  isOnline(): boolean
  subscribe(listener: (online: boolean) => void): () => void
}
```

and `services/index.ts`'s `getSyncService()` constructs this port today by reaching into `modules/connectivity.ts`:

```ts
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
```

That hand-rolled `let last = isOnline()` + edge-detection block is repeated cruft. The wiring site shouldn't have to know about xstate snapshot semantics to talk to connectivity. The Sync open question #3 says exactly this: *"When the Connectivity service refactor lands its `getConnectivityService()`, the Sync wiring site changes to `const connectivity = getConnectivityService()` and the adapter shim is deleted."* This refactor closes that loop.

Symptoms motivating the refactor:

- **xstate leaks across the module boundary.** Every caller of `connectivityActor.subscribe` has to know the snapshot has a `.value` string, and the edge-detection has to be re-implemented at each site (or risk firing on non-transitions).
- **Module-load side effects.** `modules/connectivity.ts` registers `window` listeners at import time. Tests have to import that module to use the actor, paying the side effect. There's no constructor, no factory, no test seam.
- **The hook is wired to a singleton.** `useConnectivity.ts` imports `connectivityActor` directly. There's no way to inject a fake for component tests; jsdom needs to fake `window.online/offline` instead.
- **No single owner.** `voiceChatService` (after recent voice-chat refactor) and `NetworkBanner` go through `useConnectivity`; `services/sync/index.ts` reaches into `connectivityActor` + `isOnline()` directly. Two access paths for one concept.

This refactor introduces a single renderer-side Connectivity service that **wraps** the existing xstate machine (no behavior change), exposes a small typed interface matching the `ConnectivityPort` shape Sync already consumes, and replaces every caller's import. The xstate machine + actor stay alive *inside* the service module — the wrap preserves the user's committed work while collapsing the public surface.

## Non-goals

- **Removing xstate.** The committed `connectivityMachine.ts` stays. The previous draft of this spec proposed dropping it; that decision is reversed. xstate is the internal state representation.
- **Adding active network probing.** No HTTP heartbeat, no DNS check, no per-interval reprobing. The machine listens to `window` `online`/`offline` events, period. Listed as an open question to flag (not resolve) below.
- **Adding richer states.** No `'checking'` / `'reconnecting'` intermediate state today; the machine has 2 states, and the public surface exposes a `boolean`. Listed as an open question to flag (not resolve) below.
- **Changing `NetworkBanner` behavior or layout.** Only the import path through the hook changes; UI is identical.
- **Migrating to Effect-TS.** Stage 1 is plain TypeScript. Predicted to stay plain TS indefinitely (see "Stage 2 outlook").

## Decision summary

| Question | Decision |
|---|---|
| xstate internals | **Wrapped, not dropped.** The committed `connectivityMachine.ts` becomes an internal implementation detail of `services/connectivity/`. |
| Service scope | Machine lifecycle (actor start/stop) + browser event registration + edge-detected boolean subscription + synchronous `isOnline()` snapshot. |
| Boundary | One module: `services/connectivity/`. Single factory `createConnectivityService(deps)`. |
| Public interface size | 4 methods (`isOnline`, `subscribe`, `start`, `stop`). No `EventEmitter`, no actor exposure, no snapshot string. |
| Return shape | `isOnline()` returns `boolean`. `subscribe(cb)` returns an unsubscribe function. `start()` / `stop()` return `void`. |
| Subscribe semantics | Listener fires **only on transitions** (edge-detected), never on subscribe. Matches the bespoke adapter Sync uses today; callers needing the current value at subscribe time call `isOnline()` separately. (Differs from Sync's `onStatusChange` which fires immediately; that asymmetry is intentional — Sync exposes a multi-valued status snapshot, Connectivity exposes a boolean where the "current" value is trivially readable.) |
| `start()` idempotency | Yes (lean stated in open questions; ratified in decision). Calling `start()` twice is a no-op; second invocation does not re-register listeners. |
| `stop()` idempotency | Yes. Calling `stop()` on a never-started or already-stopped service is a no-op. |
| Active probing | Not added. The machine is event-driven only. Flagged as open question to revisit if a real caller demands it. |
| Public state granularity | Boolean only at the public surface. Internal machine state (`'online' \| 'offline'`) stays internal. If `'checking'` / `'reconnecting'` are added later, they remain internal unless a caller justifies the broader surface. |
| Source dependency | Injected `source: ConnectivitySource` port — `{ onLine: boolean; addEventListener; removeEventListener }`. Production wires `window`; tests wire a fake. |
| Clock dependency | Not injected. The machine has no time-based behavior today; xstate's internal scheduler is unused. If active probing is added later, a `clock` port joins the deps record then. |
| Probe / fetch dependency | Not injected (no active probing today). |
| Machine ownership | The `connectivityMachine` import lives inside `services/connectivity/service.ts`. The machine file itself stays at `src/renderer/src/machines/connectivityMachine.ts` — no move — because it's a structurally pure xstate value and moving it inside `services/` doesn't earn anything. |
| Hook | `useConnectivity` (renamed exposing `useIsOnline` re-export) stays as a renderer hook but collapses to a thin `useSyncExternalStore` over the service's `subscribe` + `isOnline`. Lives at `services/connectivity/useIsOnline.ts`. The old `src/renderer/src/hooks/useConnectivity.ts` is deleted. |
| `NetworkBanner` | Unchanged in API and layout. One-line import path swap. |
| Sync service wiring | `services/sync` already consumes `ConnectivityPort = { isOnline, subscribe }`. The new `ConnectivityService` interface is **shape-compatible** with `ConnectivityPort`. `services/index.ts`'s `getSyncService()` block deletes the hand-rolled adapter and passes `connectivity: getConnectivityService()` directly. |
| Tests | Boundary tests at the service interface (~6 scenarios). The existing 4 `connectivityMachine.test.ts` tests **stay** as internal-implementation tests — they verify the machine's transitions, which the service relies on. They become co-located with the service folder (moved alongside the wrapper) but otherwise unchanged. |
| Wiring site | `src/renderer/src/services/index.ts` — adds `getConnectivityService()` lazy singleton alongside `getRagService` / `getTtsService` / `getSyncService` / `getBookImportService`. |

## Boundary

### What the service owns

- Construction of the xstate actor (`createActor(connectivityMachine)` + `.start()`).
- Registration of `source.addEventListener('online', …)` and `source.addEventListener('offline', …)` handlers that send `ONLINE` / `OFFLINE` events into the actor.
- Edge-detected subscription fanout: when the actor's snapshot transitions across the `'online' ↔ 'offline'` boundary, each subscriber is notified once with the new boolean. Spurious duplicates (machine receiving `OFFLINE` while already offline) do not fire.
- Synchronous `isOnline()` snapshot read.
- Lifecycle: `start()` registers listeners, `stop()` removes listeners and stops the actor.

### What stays outside

- **The `connectivityMachine` definition itself.** Lives at `machines/connectivityMachine.ts` as a pure xstate value. The service imports it; no machine-internal changes.
- **`navigator.onLine` direct reads.** Callers go through the service's `isOnline()`. The `modules/connectivity.ts` module is deleted; its `isOnline()` export is gone. The `connectivityActor` export is gone.
- **The `useSyncExternalStore` wiring.** Owned by the hook (`useIsOnline.ts`), not the service core.
- **The `NetworkBanner` UI.** Unchanged.

### What's hidden behind the interface

Callers don't see: `xstate`, `createActor`, `connectivityMachine`, `Actor`, the `.subscribe()` snapshot signature, the `snapshot.value === 'online'` string compare, the `window.addEventListener` registration, the unsubscribe flavor (`{ unsubscribe() }` returned by xstate vs. callable `() => void`), the edge-detection bookkeeping.

## Dependencies

A single dependency in Stage 1: the `ConnectivitySource` port. Category: **in-process** (per the meta-spec — no IPC, no network, locally substitutable via a hand-rolled fake).

| Dep | Category | What the service uses | Production adapter | Test adapter |
|---|---|---|---|---|
| `source` | In-process / local-substitutable | `onLine: boolean` read at construction + `addEventListener('online' \| 'offline', listener)` / `removeEventListener(...)` for transitions | `window` (already has `onLine` + the two methods natively) | `makeFakeSource({ initialOnline })` — in-memory object with `.goOnline()` / `.goOffline()` test helpers that fire the registered listeners |

Tests do **not** require: a real browser, jsdom/happy-dom, the `window` global at all. The service is testable as plain code under vitest's node environment.

Future deps (not in Stage 1, listed only so the deps record can grow without breaking the contract):

- `clock` — if active probing is added (`setInterval` for periodic reprobe). Today the machine has no time behavior.
- `probeFetch` — if active probing is added (`(url) => Promise<Response>` to hit a heartbeat endpoint).

Both are deliberately omitted. If either is added later, the `ConnectivityServiceDeps` record gains the field; the public interface (`isOnline` / `subscribe` / `start` / `stop`) does not change.

## Public interface

### Types

```ts
// src/renderer/src/services/connectivity/types.ts

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
 * so it can be passed directly into `createSyncService(deps)`.
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

/**
 * Internal-only type used by `service.ts` for the wrapped xstate actor handle.
 * Not exported from the package surface.
 */
export type ConnectivityActor = ReturnType<
  typeof import('xstate').createActor<
    typeof import('@/machines/connectivityMachine').connectivityMachine
  >
>
```

### Service factory + module exports

```ts
// src/renderer/src/services/connectivity/index.ts

export type {
  ConnectivityService,
  ConnectivityListener,
  ConnectivitySource,
  ConnectivityServiceDeps
} from './types'
export { createConnectivityService } from './service'
export { useIsOnline } from './useIsOnline'

// service.ts
export function createConnectivityService(deps: ConnectivityServiceDeps): ConnectivityService
```

### Wiring site

```ts
// src/renderer/src/services/index.ts (additive — RAG / TTS / Sync / Book Import already wired)
import { createConnectivityService, type ConnectivityService } from './connectivity'

let _connectivity: ConnectivityService | null = null

export function getConnectivityService(): ConnectivityService {
  if (!_connectivity) {
    _connectivity = createConnectivityService({ source: window })
    _connectivity.start()
  }
  return _connectivity
}

export { useIsOnline } from './connectivity'
```

Note that `getConnectivityService()` calls `start()` on first access — symmetric with how Sync's `start()` is called from `__root.tsx` lifecycle, except Connectivity has no caller-controlled lifecycle requirement (there's no per-user-session reason to stop/start). If a teardown path emerges (e.g., E2E test reset), callers can `getConnectivityService().stop()` explicitly. Otherwise the service runs for the renderer's lifetime.

### Sync service re-wiring

The hand-rolled adapter currently in `services/index.ts`'s `getSyncService()` block:

```ts
// BEFORE — services/index.ts
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
  // …
  connectivity,
  // …
})
```

collapses to a one-liner:

```ts
// AFTER — services/index.ts
_sync = createSyncService({
  // …
  connectivity: getConnectivityService(),
  // …
})
```

This works because `ConnectivityService` is shape-compatible with `ConnectivityPort` — both have `isOnline(): boolean` and `subscribe(listener: (online: boolean) => void): () => void`. The extra `start()` / `stop()` methods on `ConnectivityService` are ignored by Sync (TypeScript structural typing). No change to `services/sync/types.ts`'s `ConnectivityPort` definition is needed.

If we want to enforce the relationship in types, a one-line assertion can be added to `services/sync/types.ts`:

```ts
import type { ConnectivityService } from '@/services/connectivity'
type _PortIsCompatible = ConnectivityService extends ConnectivityPort ? true : never
```

(Stylistic — not required.)

### Hook

```ts
// src/renderer/src/services/connectivity/useIsOnline.ts
import { useSyncExternalStore } from 'react'
import { getConnectivityService } from '@/services'

export function useIsOnline(): boolean {
  const service = getConnectivityService()
  return useSyncExternalStore(
    (cb) => service.subscribe(() => cb()),
    () => service.isOnline(),
    () => true // SSR fallback — assume online
  )
}
```

The hook is the same shape as the committed `useConnectivity.ts` (same `useSyncExternalStore` + same SSR fallback). Implementation collapses from "subscribe to actor + read snapshot string" to "subscribe to service + read boolean."

### Usage example — most common callers

```ts
// modules/voiceChatService.ts (after migration)
import { getConnectivityService } from '@/services'

const conn = getConnectivityService()
const unsub = conn.subscribe((online) => {
  if (!online) {
    disposeInternal()
    actor.send({ type: 'OFFLINE' })
  } else if (actor.getSnapshot().value === 'offline') {
    actor.send({ type: 'ONLINE' })
  }
})

// Before activation:
if (!conn.isOnline()) throw new OfflineError(/* … */)
```

```ts
// components/NetworkBanner.tsx (after migration)
import { useIsOnline } from '@/services'

export function NetworkBanner(): JSX.Element | null {
  const isOnline = useIsOnline()
  if (isOnline) return null
  return (
    <div role="status" aria-live="polite" /* … */>
      <WifiOff /* … */ />
      <span>You're offline. Voice chat and sync are paused until you reconnect.</span>
    </div>
  )
}
```

## File structure & module layout

```
src/renderer/src/
├── machines/
│   ├── connectivityMachine.ts            # UNCHANGED — pure xstate value, imported by the service
│   └── __tests__/
│       └── connectivityMachine.test.ts   # UNCHANGED — 4 internal-impl tests
└── services/
    ├── index.ts                          # +getConnectivityService(); +useIsOnline re-export;
    │                                     # Sync wiring block simplified
    └── connectivity/
        ├── index.ts                      # public re-exports
        ├── types.ts                      # types from "Public interface" above
        ├── service.ts                    # createConnectivityService — wraps the xstate actor
        ├── useIsOnline.ts                # React hook (useSyncExternalStore wrapper)
        └── service.test.ts               # boundary tests
```

Deleted:

```
src/renderer/src/modules/connectivity.ts            # absorbed into services/connectivity/service.ts
src/renderer/src/hooks/useConnectivity.ts           # moved to services/connectivity/useIsOnline.ts
```

Kept verbatim:

```
src/renderer/src/machines/connectivityMachine.ts                    # imported by service.ts
src/renderer/src/machines/__tests__/connectivityMachine.test.ts     # internal-impl coverage
```

The machine + machine tests are *kept* because they are pure xstate values with no side effects, they remain meaningful as documentation of the state model, and re-locating them to `services/connectivity/` earns nothing.

## Internals (orchestration flow)

```ts
// src/renderer/src/services/connectivity/service.ts (illustrative)

import { createActor } from 'xstate'
import { connectivityMachine } from '@/machines/connectivityMachine'
import type {
  ConnectivityActor,
  ConnectivityListener,
  ConnectivityService,
  ConnectivityServiceDeps
} from './types'

export function createConnectivityService(
  deps: ConnectivityServiceDeps
): ConnectivityService {
  const { source } = deps
  const listeners = new Set<ConnectivityListener>()

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
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },

    start() {
      if (started) return
      started = true

      actor = createActor(connectivityMachine)
      actor.start()
      lastOnline = readActorOnline()

      // Sync source.onLine into the machine in case the initial machine state
      // differs from the live source. (The machine reads `navigator.onLine`
      // at module-load; if the source disagrees now, send the correcting event.)
      if (source.onLine && !lastOnline) actor.send({ type: 'ONLINE' })
      else if (!source.onLine && lastOnline) actor.send({ type: 'OFFLINE' })
      lastOnline = readActorOnline()

      onlineHandler = () => actor?.send({ type: 'ONLINE' })
      offlineHandler = () => actor?.send({ type: 'OFFLINE' })
      source.addEventListener('online', onlineHandler)
      source.addEventListener('offline', offlineHandler)

      // Edge-detected fanout. xstate fires .subscribe on every event including
      // no-op transitions; we filter to true boolean edges before notifying.
      actorSub = actor.subscribe(() => {
        const next = readActorOnline()
        if (next === lastOnline) return
        lastOnline = next
        for (const listener of listeners) listener(next)
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
      // `lastOnline` is preserved as the last-known value for `isOnline()` reads.
    }
  }
}
```

### Behavioral notes baked into the contract

- **`isOnline()` works before `start()`.** Returns `source.onLine`'s value captured at construction. Becomes machine-backed after `start()`.
- **`start()` reconciles machine vs. source.** The machine's initial state is read from `navigator.onLine` once at module load (in `connectivityMachine.ts`). If the live source disagrees at `start()` time, the service sends the correcting event so the machine matches reality.
- **`subscribe` is edge-detected.** Listeners fire only when `lastOnline !== next`. Duplicate browser `'offline'` events while already offline produce no listener calls.
- **Listeners are not invoked at subscribe time.** Callers needing the current value call `isOnline()`. (This matches the Sync open-question #3 adapter's behavior, the previous draft of this spec, and how the hook bridges via `useSyncExternalStore`'s separate snapshot read.)
- **`stop()` preserves the last-known online value.** `isOnline()` after `stop()` returns whatever it was just before stop — useful for shutdown-time reads but **not** updated until `start()` is called again.
- **No teardown-during-in-flight problem.** xstate's actor `.stop()` is synchronous and the source listeners are removed before the actor is torn down; no race exists.

### Explicitly NOT added (YAGNI per the meta-spec scope guard)

- No active network probing (HTTP heartbeat, DNS check, etc.). Open question to flag.
- No `'checking'` / `'reconnecting'` intermediate state. Open question to flag.
- No transition timestamps (`lastOfflineAt`, etc.).
- No `waitUntilOnline()` Promise helper.
- No multi-process coordination — main process plays no role in connectivity.
- No `forceRecheck()` / `recheck()` method. The machine doesn't probe today, so there's nothing to re-do.

## Migration

### Caller migration table

| File | Current | After |
|---|---|---|
| `src/renderer/src/components/NetworkBanner.tsx` | `import { useIsOnline } from '@/hooks/useConnectivity'` | `import { useIsOnline } from '@/services'` |
| `src/renderer/src/modules/voiceChatService.ts` | `import { connectivityActor, isOnline } from '@/modules/connectivity'`; subscribes via `connectivityActor.subscribe(snapshot => ...)`; calls `isOnline()` before activation | `import { getConnectivityService } from '@/services'`; subscribe via `getConnectivityService().subscribe(online => ...)`; replace `isOnline()` calls with `getConnectivityService().isOnline()` |
| `src/renderer/src/services/index.ts` (`getSyncService` block) | Hand-rolled `connectivity` adapter on top of `connectivityActor` + `isOnline` (10 lines) | One-line: `connectivity: getConnectivityService()` passed directly into `createSyncService` |
| Any other importer of `@/modules/connectivity` or `@/hooks/useConnectivity` (none today, but grep before merge) | Direct import | Service import |

### Hook collapse

| Aspect | Before (`hooks/useConnectivity.ts`) | After (`services/connectivity/useIsOnline.ts`) |
|---|---|---|
| Source of state | `connectivityActor.subscribe` + `getSnapshot().value === 'online'` | `service.subscribe(cb)` + `service.isOnline()` |
| File location | `src/renderer/src/hooks/useConnectivity.ts` | `src/renderer/src/services/connectivity/useIsOnline.ts` |
| Export name | `useIsOnline` | `useIsOnline` (unchanged) |
| Import path for callers | `@/hooks/useConnectivity` | `@/services` |
| SSR fallback | `() => true` | `() => true` (unchanged) |
| Lines | 13 | 11 |

### Files to delete

| File | Reason |
|---|---|
| `src/renderer/src/modules/connectivity.ts` | Singleton actor + `window.addEventListener` registrations + `isOnline()` helper — fully replaced by the new service. |
| `src/renderer/src/hooks/useConnectivity.ts` | Moved + collapsed to `services/connectivity/useIsOnline.ts`. |

### Files NOT deleted

| File | Reason |
|---|---|
| `src/renderer/src/machines/connectivityMachine.ts` | Pure xstate value — imported by the service. Stays. |
| `src/renderer/src/machines/__tests__/connectivityMachine.test.ts` | Tests for the kept machine. Internal-impl coverage. Stays. |

Per the meta-spec's *no shims* rule: no compatibility re-exports at `@/hooks/useConnectivity` or `@/modules/connectivity`. One PR, one source of truth.

## Test strategy

### Test placement

- **Boundary tests** at the service interface: one file, `src/renderer/src/services/connectivity/service.test.ts`. Tests construct the service with a fake source — no global mocks, no module reset between tests, no `window` polyfill.
- **Internal-implementation tests** for the machine: `machines/__tests__/connectivityMachine.test.ts` stays. The machine is a pure value; its tests are fast and document the state model.

The split is principled: the boundary tests verify the *service's contract* (edge-detection, idempotency, start/stop, isOnline accuracy). The machine tests verify the *machine's transitions* in isolation, which the service relies on. Both layers are cheap; both stay.

### Test helpers (planned shape)

```ts
function makeFakeSource(opts?: { initialOnline?: boolean }): ConnectivitySource & {
  goOnline(): void
  goOffline(): void
  setOnLine(value: boolean): void
  listenerCount(type: 'online' | 'offline'): number
}
```

The fake is ~40 lines: an internal `online: boolean`, a `Map<'online' | 'offline', Set<() => void>>`, and the three test helpers. No `vi.mock`, no jsdom.

### Boundary test scenarios (committed)

Six tests, all at the public interface. None poke internals (no `actor.getSnapshot()` calls in test code, no machine import).

1. **`isOnline()` returns the source's initial value before `start()` and after.** Setup: `makeFakeSource({ initialOnline: true })` → construct service → `isOnline() === true`. Repeat with `false`. Then call `.start()` and assert `isOnline()` matches.
2. **Online → offline transition fires listeners with `false` after `start()`.** Setup: source online; `start()`; subscribe spy; call `source.goOffline()`. Assert: spy called once with `false`; `service.isOnline() === false`.
3. **Offline → online transition fires listeners with `true` after `start()`.** Setup: source offline; `start()`; subscribe spy; call `source.goOnline()`. Assert: spy called once with `true`; `service.isOnline() === true`.
4. **Duplicate transition events are edge-detected (no double fire).** Setup: `start()`; subscribe spy; `source.goOffline()` twice consecutively without intervening `goOnline()`. Assert: spy called exactly once.
5. **`start()` and `stop()` are idempotent; `stop()` removes source listeners.** Setup: subscribe spy; `start()`; `start()` again (no-op); `source.listenerCount('online') === 1` and `('offline') === 1`. Then `stop()`; `stop()` again (no-op). Assert: listener counts are now zero. Fire `source.goOffline()` after stop → spy NOT called.
6. **Unsubscribe stops invocations; multiple subscribers each receive notifications.** Setup: `start()`; subscribe spies A and B; `source.goOffline()` → both fire once with `false`. Unsubscribe A; `source.goOnline()` → only B fires (once, with `true`).

### Internal-implementation tests (existing — kept)

The 4 tests already in `machines/__tests__/connectivityMachine.test.ts`:

1. starts in `'online'` state by default,
2. transitions to `'offline'` on `OFFLINE` event,
3. transitions back to `'online'` on `ONLINE` event,
4. `OFFLINE` while already offline is a no-op.

These verify the xstate machine's contract directly. They stay as-is — no rewrite, no relocation. They are part of the implementation's coverage; the service relies on these transitions being correct.

### Tests we explicitly do NOT add

- **SSR fallback test.** Lives in the hook (`useIsOnline.ts`), not the service. The hook's SSR snapshot returns `true`; covered by the React `useSyncExternalStore` semantics, not by a custom test.
- **Leak / teardown test under repeated start/stop.** Covered by Test 5's listener-count assertion. The actor's `.stop()` is xstate's responsibility; we don't re-verify it.
- **The exact xstate snapshot shape (`.value === 'online'`)** isn't asserted at the boundary. If the machine grows new states, only the boolean projection needs to be preserved.

### What inherited tests get deleted

None at the machine layer. The previous draft of this spec proposed deleting `connectivityMachine.test.ts`; that decision is reversed because the machine stays.

There are no tests for `modules/connectivity.ts` (only the machine has tests). The service's 6 boundary tests are net-new coverage.

## Out of scope

- **Active network probing** (HTTP heartbeat, DNS check, periodic reprobe). Open question to flag — see below.
- **Richer state surface** (`'checking'` / `'reconnecting'` exposed publicly). Open question to flag.
- **Main-process coordination** — none needed; connectivity is renderer-local.
- **Machine relocation.** `connectivityMachine.ts` stays in `machines/`. Moving it inside `services/connectivity/` is cosmetic and earns nothing.
- **Effect-TS adoption** — predicted to score 1-2 axes; service stays plain TS (with a small xstate machine inside) indefinitely.

## Development workflow — TDD

Strict TDD: red → green → commit per behavior. Each test-implementation pair is its own commit. The implementation plan (drafted separately) will encode the exact commit sequence; what follows is the spec's commitment to structure.

### PR commit sequence (~9 commits)

1. **Scaffold.** Create `services/connectivity/` with `types.ts` (full), an empty `createConnectivityService` stub in `service.ts` that throws "not implemented", public re-exports in `index.ts`, `useIsOnline.ts` (stub), and `service.test.ts` with the `makeFakeSource` helper but no `it()` blocks yet. Commit.
2. **Test 1 + impl (`isOnline()` returns source's initial value, before and after `start()`).** Red. Implement the constructor read of `source.onLine`, the `isOnline()` getter, and a minimal `start()` that creates+starts the actor + reconciles. Green. Commit.
3. **Test 2 + impl (online → offline transition).** Red. Implement the `source.addEventListener('offline', …)` hookup + actor subscription + edge-detected listener fanout. Green. Commit.
4. **Test 3 + impl (offline → online transition).** Red. Symmetric `'online'` hookup. Green. Commit.
5. **Test 4 + impl (duplicate transition events edge-detected).** Red. Add the `lastOnline === next` guard. Green. Commit (or "already green" doc commit if Step 3 already covered).
6. **Test 5 + impl (`start` / `stop` idempotent; `stop` removes listeners).** Red. Implement `stop()` + the `started` flag. Green. Commit.
7. **Test 6 + impl (unsubscribe; multiple subscribers).** Likely already green via `Set<ConnectivityListener>` fanout from Step 3. Doc commit or one-line refinement. Commit.
8. **Add `useIsOnline` hook impl (collapsing the old hook).** Implement `useIsOnline.ts` on top of the service. No new test (the hook is too thin to test meaningfully — judgment call; React's `useSyncExternalStore` semantics are tested by React). Commit.
9. **Wire + migrate.** Add `getConnectivityService()` to `services/index.ts`. Simplify the `getSyncService` block to pass `connectivity: getConnectivityService()` directly (delete the 10-line adapter). Migrate `NetworkBanner.tsx` import path. Migrate `voiceChatService.ts` to the new service. Delete `modules/connectivity.ts` and `hooks/useConnectivity.ts`. Verify `pnpm test` / `pnpm typecheck` clean. Commit.

### Expected diff

- **Added:** ~250 lines (service + types + hook + tests + wiring).
- **Removed:** ~40 lines (old `modules/connectivity.ts` + `hooks/useConnectivity.ts` + the 10-line adapter in `getSyncService`).
- **Net:** slightly positive. The deep-module discipline doesn't compress raw line count when the underlying surface is already tiny — the win is in the *shape*: one boundary instead of three, one consumer pattern instead of two.

## Open questions

These are open design questions the implementation plan should resolve. They are flagged but **not** decided in this spec.

1. **Should `start()` be idempotent?** *Lean: yes.* Mirrors the pattern in Sync and removes a footgun for tests / re-mounts. Decision summary ratifies this lean; flagged here so the plan can verify no caller relies on "second `start()` triggers a re-register."
2. **If the machine ever does active probing, should the probe URL be configurable via `config`?** *Lean: yes, with a sensible default (e.g., a fast HEAD against the worker URL).* No active probing in Stage 1; this is a forward-compatibility note for the deps record.
3. **Should the service expose the underlying machine's full state (e.g., `'online' \| 'offline' \| 'checking'`) or only the simplified boolean?** *Lean: boolean only at the public surface; richer machine state stays internal.* If a `'checking'` state is added to the machine later, the service can expose a separate `getRawState()` method without breaking `isOnline()` / `subscribe`. Today: boolean only.
4. **Should the service automatically call `start()` from the wiring site, or require callers to call it explicitly?** *Lean: auto-start in `getConnectivityService()`.* Connectivity has no per-session lifecycle; there's no point making every caller (or `__root.tsx`) call `start()` manually. If the auto-start pattern bites tests, the test path can use `createConnectivityService` directly and skip `start()`.
5. **Does the wiring site need to expose `stop()` for teardown?** *Lean: no — production never tears down.* The service exposes `stop()` for completeness (test cleanup, hypothetical E2E reset). The wiring site does not call it.

## Stage 2 outlook

Stage 2 is explicit Effect-TS adoption *inside* a service, after Stage 1 ships. The meta-spec sets a rubric: Effect goes into a service only if it scores positively on ≥2 of 5 axes.

### Scoring Connectivity against the rubric

| Axis | Score | Why |
|---|---|---|
| **Concurrency** | NO | One source, one subscription, one fanout to N listeners. No queues, no semaphores, no races worth modeling. |
| **Retry / scheduling** | NO | No retries. No periodic schedule. (Would become PARTIAL if active probing is added — `Schedule.spaced` for the probe interval — but probing is out of scope.) |
| **Resource lifecycle** | PARTIAL | `start()` / `stop()` register/unregister browser listeners — textbook `acquireRelease`. But it's a single resource pair; the imperative `start/stop` is already cleaner than a Scope program for this scale. |
| **Typed error channels** | NO | No errors. `subscribe` can't fail; `isOnline()` can't throw. |
| **Composed async pipeline** | NO | No async at all. The whole service is synchronous reads + synchronous fanouts; the actor subscription is the closest thing to a stream, and it's already one line. |

**Score:** 1 partial. **Below the ≥2 axes threshold.** Connectivity stays plain TypeScript indefinitely.

### Recommendation

**Defer Stage 2 indefinitely.** If the service ever grows active probing (Stage 1 explicitly defers this), revisit — `Schedule.spaced` for the probe interval + typed errors for probe failure could bump it to 2-3 axes. Until then, the xstate machine inside + plain-TS service wrapper outside is the right level of abstraction. Adding Effect would be paradigm consistency, not real value.

The internal xstate machine is *not* a Stage 2 retrofit target either. xstate is the right tool for a state machine; Effect doesn't replace state machines. The machine stays.

### Stage 2 trigger

Per the meta-spec, Stage 2 starts only after **all six Stage 1 services have shipped**. This spec commits no Stage 2 work and recommends Connectivity be the first service to *skip* Stage 2 evaluation when the rubric is applied.

## Definition of done

Per the meta-spec's standard. This service refactor ships when:

1. `src/renderer/src/services/connectivity/index.ts` is the single public-facing module exporting `createConnectivityService`, `ConnectivityService`, and the public types.
2. `src/renderer/src/services/index.ts` exports a `getConnectivityService()` lazy singleton **and** simplifies the `getSyncService` block to pass `connectivity: getConnectivityService()` directly.
3. All 3 production callers use the service:
   - `NetworkBanner.tsx` via `useIsOnline` from `@/services`,
   - `voiceChatService.ts` via `getConnectivityService()` directly,
   - `services/sync` via the dep injection at the wiring site.
4. The 2 old files are **deleted**, not kept as shims: `modules/connectivity.ts`, `hooks/useConnectivity.ts`.
5. The 2 retained files are **untouched**: `machines/connectivityMachine.ts`, `machines/__tests__/connectivityMachine.test.ts`.
6. All 6 boundary tests pass; all 4 existing machine tests still pass.
7. `tsc`, `eslint`, `vitest` clean across the app.
