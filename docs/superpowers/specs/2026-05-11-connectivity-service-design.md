# Connectivity service — design

**Status:** draft 2026-05-11
**Parent:** [`2026-05-11-services-and-effect-adoption-design.md`](./2026-05-11-services-and-effect-adoption-design.md) (meta-spec)
**Scope:** Wave 1, service #2 of 6. Stage 1 only (plain TypeScript). `apps/rishi-electron` renderer-side service that owns "are we online right now?" as a single source of truth.

## Background

Today, online/offline detection is split across two parallel systems in the renderer:

1. **An xstate-backed singleton actor** — `src/renderer/src/modules/connectivity.ts` exposes `connectivityActor` and an `isOnline()` helper. Backed by `src/renderer/src/machines/connectivityMachine.ts` (2 states, 2 events, no context). The actor subscribes to `window`'s online/offline events at module load. Consumers: `voiceChatService` (subscribes for offline teardown, reads `isOnline()` before activation), `NetworkBanner` (via the `useIsOnline` hook).
2. **Raw `navigator.onLine` + ad-hoc `window` event listeners** — `src/renderer/src/modules/sync-triggers.ts` reads `navigator.onLine` directly (3 places) and registers its own `window.addEventListener('online'/'offline', ...)` handlers. It does NOT use the connectivity actor.

There is no single owner of "are we online?" The two systems coexist with subtly different debounce semantics. The xstate machine has 16 LOC of setup for what is functionally a 5-line plain-TS observer pattern. The main process plays no role; there are no active network probes.

This refactor unifies both systems behind a single `ConnectivityService` exposed via `getConnectivityService()` at the renderer's well-known wiring site. Internals drop xstate in favor of plain TypeScript at this complexity. All callers — including `sync-triggers` — migrate.

## Decision summary

| Question | Decision |
|---|---|
| xstate internals | Dropped. Plain TS observer pattern. (xstate at 2 states / 2 events is pure ceremony.) |
| Active network probing | No. Pure passive `online`/`offline` event listening, matching current behavior. |
| Migration scope | All current connectivity readers, including `sync-triggers.ts`'s raw `navigator.onLine` access. Zero raw `navigator.onLine` reads remain in the renderer after this refactor. |
| React hook location | Co-located inside the service folder (`services/connectivity/useIsOnline.ts`). `hooks/useConnectivity.ts` is deleted. |
| Subscribe semantics | Listener invoked **only on transitions**, never on subscribe. Callers needing the current value at subscribe time call `isOnline()` separately. |
| Dependency strategy | In-process; `ConnectivitySource` injected at the factory boundary. Production wires `window`; tests wire a fake. |
| Wiring site | `src/renderer/src/services/index.ts` — adds `getConnectivityService()` alongside the existing `getRagService()`. |
| Development workflow | TDD — red → green → commit per behavior. 6 boundary tests, 14-commit PR. |

## Stage 2 Effect-TS prediction

Per the meta-spec rubric, Connectivity scores zero axes. It stays plain TypeScript indefinitely.

## Public interface

```ts
// src/renderer/src/services/connectivity/types.ts

export type ConnectivityListener = (online: boolean) => void

export interface ConnectivityService {
  /** Synchronous: is the renderer currently online? */
  isOnline(): boolean

  /**
   * Subscribe to online/offline transitions.
   * Listener is invoked only on STATE CHANGES (not on subscribe).
   * Returns an unsubscribe function.
   */
  subscribe(listener: ConnectivityListener): () => void
}

export interface ConnectivitySource {
  readonly onLine: boolean
  addEventListener(type: 'online' | 'offline', listener: () => void): void
  removeEventListener(type: 'online' | 'offline', listener: () => void): void
}

export interface ConnectivityServiceDeps {
  source: ConnectivitySource
}
```

```ts
// src/renderer/src/services/connectivity/index.ts

export type {
  ConnectivityService,
  ConnectivityListener,
  ConnectivitySource,
  ConnectivityServiceDeps,
} from './types'
export { createConnectivityService } from './service'
export { useIsOnline } from './useIsOnline'
```

```ts
// src/renderer/src/services/index.ts (additive — getRagService already exists)

import { createConnectivityService, type ConnectivityService } from './connectivity'

let _connectivity: ConnectivityService | null = null

export function getConnectivityService(): ConnectivityService {
  if (!_connectivity) {
    _connectivity = createConnectivityService({ source: window })
  }
  return _connectivity
}

export { useIsOnline } from './connectivity'
```

### Usage examples

```ts
// voiceChatService.ts — subscribe + sync read
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
if (!conn.isOnline()) throw new OfflineError(...)
```

```ts
// sync-triggers.ts — single subscription replaces 2 window listeners + 3 navigator.onLine reads
const conn = getConnectivityService()
const unsub = conn.subscribe((online) => {
  if (online && syncStatus === 'offline') {
    void triggerSync()
  } else if (!online) {
    syncStatus = 'offline'
    notifyListeners()
  }
})

// Periodic check (existing logic):
if (conn.isOnline()) {
  void triggerSync()
}
```

```ts
// NetworkBanner.tsx — hook unchanged in shape, import path changes
import { useIsOnline } from '@/services'
function NetworkBanner() {
  const isOnline = useIsOnline()
  if (isOnline) return null
  return <Banner>You're offline. …</Banner>
}
```

## What's hidden behind the interface

The service owns the entire "are we online?" concept for the renderer: subscription to browser events, debouncing of duplicate events, state cache, fan-out to multiple listeners. Callers see a 2-method interface (plus the hook). They don't see `window.addEventListener`, don't see `navigator.onLine`, don't see xstate.

## File structure & module layout

```
src/renderer/src/services/
├── index.ts                           # adds getConnectivityService() + re-exports useIsOnline
└── connectivity/
    ├── index.ts                       # public exports
    ├── types.ts                       # types
    ├── service.ts                     # createConnectivityService implementation
    ├── useIsOnline.ts                 # React hook bound to the service
    └── service.test.ts                # boundary tests (vitest)
```

### `useIsOnline` hook

```ts
// src/renderer/src/services/connectivity/useIsOnline.ts
import { useSyncExternalStore } from 'react'
import { getConnectivityService } from '@/services'

export function useIsOnline(): boolean {
  const service = getConnectivityService()
  return useSyncExternalStore(
    (cb) => service.subscribe(() => cb()),
    () => service.isOnline(),
    () => true, // SSR fallback — assume online
  )
}
```

The hook is part of the service's public surface; it lives in the service folder, not in `hooks/`.

## Dependency strategy

**Single dependency: `ConnectivitySource`.** Category: **in-process** (per the meta-spec — no IPC, no network). The browser event surface is locally substitutable via a tiny hand-rolled fake.

| Dep | Production adapter | Test adapter |
|---|---|---|
| `ConnectivitySource` | `window` (already has `onLine`, `addEventListener('online' \| 'offline', ...)`, `removeEventListener(...)`) | `createFakeSource(initial)` returning an object with `onLine` + the two event methods, plus test-only `goOnline()` / `goOffline()` helpers |

Tests do **not** require: a real browser, jsdom/happy-dom internals, the `window` global at all. The service is testable as plain code under vitest's node environment.

## Internals (orchestration flow)

```ts
// service.ts (illustrative — implementation may differ in style but must match behavior)

import type {
  ConnectivityService,
  ConnectivityServiceDeps,
  ConnectivityListener,
} from './types'

export function createConnectivityService(deps: ConnectivityServiceDeps): ConnectivityService {
  const { source } = deps

  let currentOnline = source.onLine
  const listeners = new Set<ConnectivityListener>()

  const onOnline = (): void => {
    if (currentOnline) return
    currentOnline = true
    listeners.forEach((listener) => listener(true))
  }

  const onOffline = (): void => {
    if (!currentOnline) return
    currentOnline = false
    listeners.forEach((listener) => listener(false))
  }

  source.addEventListener('online', onOnline)
  source.addEventListener('offline', onOffline)

  return {
    isOnline() {
      return currentOnline
    },
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}
```

### Behavioral notes baked into the contract

- **Initial state read from `source.onLine` at construction.** No SSR fallback inside the service — that lives in `useIsOnline` via `useSyncExternalStore`'s server-snapshot parameter.
- **Listener invoked only on actual transitions.** Guarded by `if (currentOnline === newValue) return` semantics. Resilient to spurious duplicate events.
- **Unsubscribe via returned function.** `listeners.delete(listener)` in a closure.
- **No teardown of source listeners.** The service is a process singleton.

### Explicitly NOT added (YAGNI per meta-spec scope guard)

- No active network probing (HTTP heartbeat, DNS check, etc.).
- No transition timestamps (`lastOfflineAt`, etc.).
- No `waitUntilOnline()` Promise helper.
- No multi-process coordination — main process plays no role.

## Boundary test scenarios

Six tests, all at the public interface. No tests poke internals.

### Test 1: `isOnline()` returns the source's initial value

Setup: `createFakeSource(true)` → service.isOnline() === true. `createFakeSource(false)` → service.isOnline() === false.

### Test 2: Online → offline transition fires listeners with `false`

Setup: fake source online. Subscribe spy. Call `.goOffline()` on the fake.

Assertions: spy called once with `false`. `service.isOnline()` now `false`.

### Test 3: Offline → online transition fires listeners with `true`

Setup: fake source offline. Subscribe spy. Call `.goOnline()`.

Assertions: spy called once with `true`. `service.isOnline()` now `true`.

### Test 4: Duplicate transition events are debounced

Setup: subscribe spy. Fire `.goOffline()` twice consecutively without an intervening `.goOnline()`.

Assertions: spy invoked once, not twice.

### Test 5: Unsubscribe stops invocations

Setup: subscribe spy, call returned unsubscribe function, fire `.goOffline()`.

Assertions: spy NOT called.

### Test 6: Multiple subscribers each receive notifications

Setup: subscribe spies A and B. Fire `.goOffline()`. Unsubscribe A. Fire `.goOnline()`.

Assertions: A called once (with `false`). B called twice (`false` then `true`).

### Tests we explicitly do NOT add

- No SSR test — SSR fallback lives in `useIsOnline`, not the service.
- No leak / teardown test — service is a process singleton.

## Caller migration

| File | Current | After |
|---|---|---|
| `src/renderer/src/modules/voiceChatService.ts` (~line 15 imports; ~lines 66-75 subscription; ~lines 171, 205 sync checks) | Imports `connectivityActor, isOnline` from `@/modules/connectivity`; subscribes via `connectivityActor.subscribe(snapshot => ...)`; calls `isOnline()` before activation | Import `getConnectivityService` from `@/services`; subscribe via `getConnectivityService().subscribe(online => ...)`; replace `isOnline()` calls with `getConnectivityService().isOnline()` |
| `src/renderer/src/modules/sync-triggers.ts` (lines 120, 160 reads; lines 147-156 listeners) | 3 direct `navigator.onLine` reads + raw `window.addEventListener('online'/'offline', ...)` handlers | Replace `navigator.onLine` with `getConnectivityService().isOnline()`; replace both window event listeners with a single `getConnectivityService().subscribe(...)`. Store the unsubscribe function in the existing teardown path. |
| `src/renderer/src/components/NetworkBanner.tsx` | `import { useIsOnline } from '@/hooks/useConnectivity'` | `import { useIsOnline } from '@/services'` |

### Subtle behavioral change in `sync-triggers`

Today, `sync-triggers`'s window listeners fire on every browser event, including spurious duplicates. After migration, they go through the service's transition-only guard. If the browser ever fires a duplicate `offline` event, the new code won't double-trigger `notifyListeners()` like the old code might. This is strictly better behavior; flagging because it's a quiet correctness improvement.

## Files / code to delete

| Location | Why |
|---|---|
| `src/renderer/src/modules/connectivity.ts` | Singleton actor + helpers — fully replaced by the new service |
| `src/renderer/src/machines/connectivityMachine.ts` | xstate machine dropped per the decision summary |
| `src/renderer/src/machines/__tests__/connectivityMachine.test.ts` | Tests for the deleted machine — coverage recovered at the service boundary |
| `src/renderer/src/hooks/useConnectivity.ts` | Replaced by `services/connectivity/useIsOnline.ts` |

## Out of scope

- **No changes to `__root.tsx`** — it just mounts `<NetworkBanner />` and doesn't touch connectivity logic.
- **Active network probing** — explicitly deferred (no caller needs it today; meta-spec scope guard).
- **`sync-triggers.ts`'s broader internals** (debounce, retry, sync orchestration) — that's the Sync service refactor's territory. This refactor touches only the *connectivity reading* parts of `sync-triggers`.
- **Effect-TS adoption** — predicted to score zero axes; service stays plain TS indefinitely.

## Development workflow — TDD

Strict TDD: red → green → commit per behavior. Each test-implementation pair is its own commit.

### PR commit sequence (14 commits)

1. **Scaffold.** Create `services/connectivity/` folder with `types.ts`, an empty `createConnectivityService` stub in `service.ts` that throws "not implemented", public re-exports in `index.ts`, and `service.test.ts` with the `createFakeSource` helper (no `it()` blocks yet). Commit.
2. **Test 1 + impl** (`isOnline()` returns source's initial value). Red. Implement the constructor read of `source.onLine` + the `isOnline()` getter. Green. Commit.
3. **Test 2 + impl** (online → offline transition). Red. Implement the `addEventListener('offline', ...)` hookup that updates state and fires listeners. Green. Commit.
4. **Test 3 + impl** (offline → online transition). Red. Implement the symmetric `addEventListener('online', ...)` hookup. Green. Commit.
5. **Test 4 + impl** (duplicate transition debounce). Red. Add the `if (currentOnline === newValue) return` guard. Green. Commit.
6. **Test 5 + impl** (unsubscribe stops invocations). Likely already green after Step 3 — if so, behavior-documentation commit (no impl change). Commit.
7. **Test 6 + impl** (multiple subscribers each receive notifications). Likely already green via the `Set<ConnectivityListener>` fan-out from Step 3. If so, behavior-documentation commit. Commit.
8. **Add `useIsOnline` hook.** Create `services/connectivity/useIsOnline.ts`. No new tests (the hook is too thin to test meaningfully — judgment call). Commit.
9. **Wire `getConnectivityService()` in `services/index.ts`.** Additive — RAG getter untouched. Re-export `useIsOnline` for caller ergonomics. Commit.
10. **Migrate `voiceChatService.ts`.** Replace actor subscription + `isOnline()` calls with the service. Update any existing tests that mocked `connectivityActor` directly. Commit.
11. **Migrate `sync-triggers.ts`.** Replace raw `navigator.onLine` reads + window event listeners with a single `getConnectivityService().subscribe(...)` call. Commit.
12. **Migrate `NetworkBanner.tsx`.** One-line import path change. Commit.
13. **Delete dead code.** Remove `modules/connectivity.ts`, `machines/connectivityMachine.ts`, the machine's test file, and `hooks/useConnectivity.ts`. Verify `pnpm test` passes. Commit.
14. **Final verification.** `pnpm typecheck`, `pnpm lint`, `pnpm test` clean. No new commit unless something fails.

### Workflow rules

- Each commit either adds a red test, makes a red test green, or completes a non-behavioral step.
- After Step 7, all 6 service tests are green; service is feature-complete.
- If a caller migration breaks a pre-existing test that was testing now-deleted shallow code, delete the obsolete test in the same commit as the migration.

### Expected diff size

Roughly **+200 / -80** lines. One PR, one sitting.

## Definition of done

Per the meta-spec's standard. This service refactor ships when:

1. `src/renderer/src/services/connectivity/index.ts` is the single public-facing module exporting the service.
2. All 3 callers (`voiceChatService`, `sync-triggers`, `NetworkBanner`) use the service via `getConnectivityService()` or `useIsOnline()`.
3. The 4 old files are **deleted**, not kept as shims.
4. All 6 boundary tests pass.
5. `tsc`, `eslint`, `vitest` clean across the app.
