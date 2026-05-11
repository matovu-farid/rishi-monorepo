# Connectivity Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a renderer-side Connectivity service in `apps/rishi-electron` that owns "are we online?" behind a small 2-method interface plus a React hook. Replace the xstate-backed actor and the parallel raw `navigator.onLine` usage with a single source of truth.

**Architecture:** Plain TypeScript factory function `createConnectivityService(deps)` returning a `ConnectivityService` with `isOnline` + `subscribe`. One injected dependency (`ConnectivitySource`) — production wires `window`, tests wire a hand-rolled fake. React glue lives in `useIsOnline()`. The xstate machine is dropped (pure ceremony at 2 states / 2 events). Singleton accessed via `getConnectivityService()` on the existing `services/index.ts` wiring site.

**Tech Stack:** TypeScript 5, Vitest 4, React 19 (`useSyncExternalStore`).

**Spec:** [`docs/superpowers/specs/2026-05-11-connectivity-service-design.md`](../specs/2026-05-11-connectivity-service-design.md)

**Parent meta-spec:** [`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md`](../specs/2026-05-11-services-and-effect-adoption-design.md)

---

## Plan overview

- **Tasks 1–7 — Build the service (TDD).** Scaffold, then six red→green test/implementation pairs. After Task 7 the service is feature-complete and tested in isolation.
- **Task 8 — Add the React hook.** Thin glue over `getConnectivityService()` + `useSyncExternalStore`.
- **Task 9 — Wire the singleton.** Additive change to `services/index.ts` — the same wiring site the RAG service uses.
- **Tasks 10–12 — Migrate callers** (`voiceChatService`, `sync-triggers`, `NetworkBanner`).
- **Task 13 — Delete dead code** (`modules/connectivity.ts`, `machines/connectivityMachine.ts` + its test, `hooks/useConnectivity.ts`).
- **Task 14 — Final verification + PR.**

No prerequisite work (unlike the RAG plan, which had a Task 0 bug-fix PR). All paths below are relative to the monorepo root (`/Users/faridmatovu/projects/rishi-monorepo`); all commands should be run from `apps/rishi-electron` unless otherwise stated.

---

## Task 1: Scaffold service folder, types, and stub implementation

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/types.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/index.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`

- [ ] **Step 1: Create a new branch off main**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git checkout main
git pull
git checkout -b refactor/connectivity-service
```

- [ ] **Step 2: Create `types.ts`**

Create `apps/rishi-electron/src/renderer/src/services/connectivity/types.ts`:

```ts
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

- [ ] **Step 3: Create `service.ts` with a "not implemented" stub**

Create `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`:

```ts
import type { ConnectivityService, ConnectivityServiceDeps } from './types'

export function createConnectivityService(_deps: ConnectivityServiceDeps): ConnectivityService {
  return {
    isOnline() {
      throw new Error('not implemented')
    },
    subscribe(_listener) {
      throw new Error('not implemented')
    },
  }
}
```

- [ ] **Step 4: Create `index.ts` re-exporting public surface**

Create `apps/rishi-electron/src/renderer/src/services/connectivity/index.ts`:

```ts
export type {
  ConnectivityService,
  ConnectivityListener,
  ConnectivitySource,
  ConnectivityServiceDeps,
} from './types'
export { createConnectivityService } from './service'
```

Note: `useIsOnline` will be added in Task 8 and re-exported then. Don't pre-add the export now.

- [ ] **Step 5: Create `service.test.ts` with the `createFakeSource` helper (no `it()` blocks yet)**

Create `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`:

```ts
import type { ConnectivitySource } from './index'

type Handler = () => void

/**
 * Build a fake ConnectivitySource. Returns an object that satisfies the
 * `ConnectivitySource` interface PLUS two test-only helpers:
 *   - `goOnline()`  — sets `onLine = true` and fires queued 'online' handlers.
 *   - `goOffline()` — sets `onLine = false` and fires queued 'offline' handlers.
 */
export function createFakeSource(initial: boolean = true) {
  const handlers: { online: Set<Handler>; offline: Set<Handler> } = {
    online: new Set(),
    offline: new Set(),
  }

  const source = {
    onLine: initial,
    addEventListener(type: 'online' | 'offline', handler: Handler) {
      handlers[type].add(handler)
    },
    removeEventListener(type: 'online' | 'offline', handler: Handler) {
      handlers[type].delete(handler)
    },
    goOnline() {
      source.onLine = true
      handlers.online.forEach((h) => h())
    },
    goOffline() {
      source.onLine = false
      handlers.offline.forEach((h) => h())
    },
  }

  return source
}

// Satisfies the `ConnectivitySource` shape (the readonly `onLine` is a wider
// constraint than the fake's mutable field; TS allows the assignment).
const _typeCheck: ConnectivitySource = createFakeSource()
void _typeCheck
```

- [ ] **Step 6: Verify scaffold compiles and test file is discovered**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: vitest finds the file and reports "no tests found" (the file exports only a helper). Acceptable.

- [ ] **Step 7: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/
git commit -m "refactor(connectivity): scaffold renderer-side Connectivity service folder

Types, empty createConnectivityService stub, public re-exports, and the
createFakeSource test helper. No behavior yet; subsequent commits add
tests + minimal implementation per behavior (TDD)."
```

---

## Task 2: TDD pair — Test 1: `isOnline()` returns the source's initial value

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`

- [ ] **Step 1: Append Test 1 to `service.test.ts` (failing)**

After the `createFakeSource` helper and the `_typeCheck` block, append:

```ts
import { describe, it, expect } from 'vitest'
import { createConnectivityService } from './index'

describe('ConnectivityService.isOnline', () => {
  it('returns true when the source starts online', () => {
    const source = createFakeSource(true)
    const service = createConnectivityService({ source })
    expect(service.isOnline()).toBe(true)
  })

  it('returns false when the source starts offline', () => {
    const source = createFakeSource(false)
    const service = createConnectivityService({ source })
    expect(service.isOnline()).toBe(false)
  })
})
```

- [ ] **Step 2: Run tests — expect 2 RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 2 tests fail with `Error: not implemented` thrown from `isOnline`.

- [ ] **Step 3: Implement the minimal `isOnline` reading the source's initial value**

Replace the contents of `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`:

```ts
import type { ConnectivityService, ConnectivityServiceDeps } from './types'

export function createConnectivityService(deps: ConnectivityServiceDeps): ConnectivityService {
  const { source } = deps
  const currentOnline = source.onLine

  return {
    isOnline() {
      return currentOnline
    },
    subscribe(_listener) {
      throw new Error('not implemented')
    },
  }
}
```

- [ ] **Step 4: Run tests — expect 2 GREEN**

```bash
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/service.ts
git commit -m "test(connectivity): isOnline reads the source's initial value"
```

---

## Task 3: TDD pair — Test 2: online → offline transition fires listeners with `false`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`

- [ ] **Step 1: Append Test 2 (failing)**

Add a new `describe` block at the bottom of `service.test.ts`:

```ts
import { vi } from 'vitest'

describe('ConnectivityService.subscribe', () => {
  it('fires listeners with false on online → offline transition', () => {
    const source = createFakeSource(true)
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.subscribe(spy)

    source.goOffline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(false)
    expect(service.isOnline()).toBe(false)
  })
})
```

If `import { vi } from 'vitest'` would duplicate the existing imports at the top of the file, consolidate to a single line: `import { describe, it, expect, vi } from 'vitest'`.

- [ ] **Step 2: Run tests — expect 1 RED (Test 2) + 2 GREEN (Test 1's)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 1 fails (`Error: not implemented` from `subscribe`), 2 pass.

- [ ] **Step 3: Implement `subscribe` + the offline-event hookup that updates state and fires listeners**

Replace the contents of `service.ts` with:

```ts
import type {
  ConnectivityListener,
  ConnectivityService,
  ConnectivityServiceDeps,
} from './types'

export function createConnectivityService(deps: ConnectivityServiceDeps): ConnectivityService {
  const { source } = deps

  let currentOnline = source.onLine
  const listeners = new Set<ConnectivityListener>()

  source.addEventListener('offline', () => {
    currentOnline = false
    listeners.forEach((listener) => listener(false))
  })

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

- [ ] **Step 4: Run tests — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/service.ts
git commit -m "test(connectivity): subscribe fires listeners on online → offline"
```

---

## Task 4: TDD pair — Test 3: offline → online transition fires listeners with `true`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`

- [ ] **Step 1: Append Test 3 (failing) inside the existing `describe('ConnectivityService.subscribe', ...)` block**

After Test 2's `it(...)`, add:

```ts
  it('fires listeners with true on offline → online transition', () => {
    const source = createFakeSource(false)
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.subscribe(spy)

    source.goOnline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(true)
    expect(service.isOnline()).toBe(true)
  })
```

- [ ] **Step 2: Run tests — expect 1 RED (Test 3) + 3 GREEN**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 1 fails (the new test — the spy is not called because there's no 'online' handler yet), 3 pass.

- [ ] **Step 3: Add the symmetric `online` event handler**

In `service.ts`, after the existing `source.addEventListener('offline', ...)` block, add:

```ts
  source.addEventListener('online', () => {
    currentOnline = true
    listeners.forEach((listener) => listener(true))
  })
```

The full updated section should look like:

```ts
  source.addEventListener('offline', () => {
    currentOnline = false
    listeners.forEach((listener) => listener(false))
  })

  source.addEventListener('online', () => {
    currentOnline = true
    listeners.forEach((listener) => listener(true))
  })
```

- [ ] **Step 4: Run tests — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/service.ts
git commit -m "test(connectivity): subscribe fires listeners on offline → online"
```

---

## Task 5: TDD pair — Test 4: duplicate transition events are debounced

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.ts`

- [ ] **Step 1: Append Test 4 (failing) inside `describe('ConnectivityService.subscribe', ...)`**

```ts
  it('debounces duplicate offline events: listener fires only once', () => {
    const source = createFakeSource(true)
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.subscribe(spy)

    source.goOffline()
    source.goOffline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(false)
  })
```

- [ ] **Step 2: Run tests — expect 1 RED + 4 GREEN**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: the new test fails (`spy` called twice, expected once).

- [ ] **Step 3: Add transition guards to both event handlers**

Update both handlers in `service.ts` to short-circuit when the state hasn't actually changed:

```ts
  source.addEventListener('offline', () => {
    if (!currentOnline) return
    currentOnline = false
    listeners.forEach((listener) => listener(false))
  })

  source.addEventListener('online', () => {
    if (currentOnline) return
    currentOnline = true
    listeners.forEach((listener) => listener(true))
  })
```

- [ ] **Step 4: Run tests — expect 5 GREEN**

```bash
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/service.ts
git commit -m "test(connectivity): subscribe debounces duplicate transition events"
```

---

## Task 6: TDD pair — Test 5: unsubscribe stops invocations

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`

- [ ] **Step 1: Append Test 5 (likely already green) inside `describe('ConnectivityService.subscribe', ...)`**

```ts
  it('returned unsubscribe stops the listener from being invoked', () => {
    const source = createFakeSource(true)
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    const unsubscribe = service.subscribe(spy)

    unsubscribe()
    source.goOffline()

    expect(spy).not.toHaveBeenCalled()
    expect(service.isOnline()).toBe(false) // state still updates internally
  })
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 6 tests pass. This test was already green because `service.ts` returns an unsubscribe function from `subscribe` that does `listeners.delete(listener)`. No code change needed — this is a behavior-documentation test.

If the test unexpectedly fails, investigate (likely a missing `listeners.delete` in the returned function).

- [ ] **Step 3: Commit (test-only — no impl change)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts
git commit -m "test(connectivity): subscribe returns an unsubscribe function"
```

---

## Task 7: TDD pair — Test 6: multiple subscribers each receive notifications

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts`

- [ ] **Step 1: Append Test 6 (likely already green) inside `describe('ConnectivityService.subscribe', ...)`**

```ts
  it('fans out notifications to all subscribed listeners', () => {
    const source = createFakeSource(true)
    const service = createConnectivityService({ source })
    const spyA = vi.fn()
    const spyB = vi.fn()
    const unsubA = service.subscribe(spyA)
    service.subscribe(spyB)

    source.goOffline()

    expect(spyA).toHaveBeenCalledTimes(1)
    expect(spyA).toHaveBeenCalledWith(false)
    expect(spyB).toHaveBeenCalledTimes(1)
    expect(spyB).toHaveBeenCalledWith(false)

    unsubA()
    source.goOnline()

    expect(spyA).toHaveBeenCalledTimes(1) // unchanged
    expect(spyB).toHaveBeenCalledTimes(2)
    expect(spyB).toHaveBeenLastCalledWith(true)
  })
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 7 tests pass. Already green via the `Set<ConnectivityListener>` fan-out implemented in Task 3. No code change needed.

If the test unexpectedly fails, investigate (likely a bug in the fan-out loop).

- [ ] **Step 3: Commit (test-only)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/service.test.ts
git commit -m "test(connectivity): subscribe fans out to multiple listeners"
```

---

## Task 8: Add the `useIsOnline` React hook

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/connectivity/index.ts`

- [ ] **Step 1: Create the hook**

Create `apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.ts`:

```ts
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

Note: this file imports `getConnectivityService` from `@/services`, which doesn't exist yet — it's wired in Task 9. TypeScript will flag this until Task 9 lands. That's expected; the test commands in this task skip typecheck.

- [ ] **Step 2: Re-export the hook from `service/connectivity/index.ts`**

Update `apps/rishi-electron/src/renderer/src/services/connectivity/index.ts` to add the hook export:

```ts
export type {
  ConnectivityService,
  ConnectivityListener,
  ConnectivitySource,
  ConnectivityServiceDeps,
} from './types'
export { createConnectivityService } from './service'
export { useIsOnline } from './useIsOnline'
```

- [ ] **Step 3: Verify the service tests still pass (no hook test here — hook is too thin)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 7 tests pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/connectivity/useIsOnline.ts \
        apps/rishi-electron/src/renderer/src/services/connectivity/index.ts
git commit -m "feat(connectivity): add useIsOnline React hook

Thin glue: useSyncExternalStore subscribes to the service; provides
an SSR fallback of 'online'. The service singleton is wired in the
next commit; this commit will not typecheck against @/services until
then."
```

---

## Task 9: Wire `getConnectivityService()` in `services/index.ts`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/index.ts`

- [ ] **Step 1: Add the `getConnectivityService` getter and re-export `useIsOnline`**

Open `apps/rishi-electron/src/renderer/src/services/index.ts`. It currently has only `getRagService` and its imports. Add the connectivity wiring **additively** (don't touch the RAG getter):

```ts
import { createRagService, type RagService } from './rag'
import { createConnectivityService, type ConnectivityService } from './connectivity'
import { embedSingleText } from '@/modules/embed-fallback'

let _rag: RagService | null = null
let _connectivity: ConnectivityService | null = null

export function getRagService(): RagService {
  if (!_rag) {
    _rag = createRagService({
      ipc: {
        searchVectors: window.electron.searchVectors,
        getTextFromVectorId: window.electron.getTextFromVectorId,
        searchBookText: window.electron.searchBookText,
        hasVectorsForBook: window.electron.hasVectorsForBook
      },
      embed: embedSingleText
    })
  }
  return _rag
}

export function getConnectivityService(): ConnectivityService {
  if (!_connectivity) {
    _connectivity = createConnectivityService({ source: window })
  }
  return _connectivity
}

export { useIsOnline } from './connectivity'
```

If `services/index.ts` differs in style (e.g., different formatting), preserve the existing style — only the `_connectivity` declaration, the `getConnectivityService` function, and the `useIsOnline` re-export are new.

- [ ] **Step 2: Verify typecheck passes for the new wiring**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck 2>&1 | grep -E "services/(connectivity|index)" | head -10
```

Expected: no errors specific to the connectivity service or the wiring file. Pre-existing errors in unrelated files (`embeddings.ts`, view components, etc.) are not your concern.

- [ ] **Step 3: Run the service tests again**

```bash
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: 7 tests pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "feat(connectivity): wire production singleton via getConnectivityService

Adds the second service getter alongside getRagService at the existing
renderer-side wiring site. Production wires window as the source; tests
inject createFakeSource() at the factory boundary directly."
```

---

## Task 10: Migrate `voiceChatService.ts`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts`

- [ ] **Step 1: Replace the connectivity import**

In `apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts`, find the line:

```ts
import { connectivityActor, isOnline } from '@/modules/connectivity'
```

(around line 15). Replace it with:

```ts
import { getConnectivityService } from '@/services'
```

- [ ] **Step 2: Replace the actor subscription block**

Find the block around lines 66–75 that looks like:

```ts
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
```

Replace it with:

```ts
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

Behavior is unchanged: same conditions, same effects, only the input type changed from an xstate snapshot to a plain boolean.

- [ ] **Step 3: Replace the two `isOnline()` synchronous reads**

Find the two sites (around lines 171 and 205) that read `isOnline()`:

```ts
if (!isOnline()) return
```

and

```ts
if (!isOnline()) {
```

Replace each `isOnline()` call with `getConnectivityService().isOnline()`. Two changes total. Don't change the surrounding control flow.

- [ ] **Step 4: Verify the file still compiles + service tests still pass**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck 2>&1 | grep voiceChatService | head -5
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: no new errors in `voiceChatService.ts`; 7 connectivity service tests pass.

- [ ] **Step 5: Update any existing voiceChatService tests that mock `connectivityActor`**

```bash
grep -rn "connectivityActor" apps/rishi-electron/src/renderer/src/modules/__tests__/ 2>/dev/null
```

If any test file mocks `connectivityActor` directly, update it to mock `@/services` instead — replacing the mock with `vi.mock('@/services', () => ({ getConnectivityService: () => ({ isOnline: () => true, subscribe: vi.fn(() => () => {}) }) }))` or similar. If no test files reference `connectivityActor`, skip this step.

```bash
pnpm vitest run src/renderer/src/modules/voiceChatService.test.ts 2>&1 | tail -5
```

Expected: tests pass (possibly after the mock update).

- [ ] **Step 6: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts \
        apps/rishi-electron/src/renderer/src/modules/voiceChatService.test.ts 2>/dev/null || true
git commit -m "refactor(connectivity): migrate voiceChatService to Connectivity service

Replaces connectivityActor.subscribe() with getConnectivityService().subscribe(online => ...);
replaces isOnline() calls with getConnectivityService().isOnline(). Behavior unchanged."
```

(If the test file wasn't modified, the `git add ... 2>/dev/null || true` simply skips it.)

---

## Task 11: Migrate `sync-triggers.ts`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/sync-triggers.ts`

This caller has the most consolidation impact: 3 raw `navigator.onLine` reads + 2 separate window event listeners collapse to one `subscribe` call.

- [ ] **Step 1: Add the service import**

Open `apps/rishi-electron/src/renderer/src/modules/sync-triggers.ts`. Near the top imports, add:

```ts
import { getConnectivityService } from '@/services'
```

- [ ] **Step 2: Replace the module-level `onlineHandler` / `offlineHandler` declarations**

Near the top of the module (around lines 21–22), find:

```ts
let onlineHandler: (() => void) | null = null
let offlineHandler: (() => void) | null = null
```

Replace with a single unsubscribe slot:

```ts
let connectivityUnsubscribe: (() => void) | null = null
```

- [ ] **Step 3: Replace the `navigator.onLine` check inside the error handler**

Find around line 120:

```ts
    } else if (!navigator.onLine) {
      syncStatus = 'offline'
    } else {
```

Replace `!navigator.onLine` with `!getConnectivityService().isOnline()`:

```ts
    } else if (!getConnectivityService().isOnline()) {
      syncStatus = 'offline'
    } else {
```

- [ ] **Step 4: Replace the two window event listeners in `initDesktopSync`**

Find around lines 146–156:

```ts
  // Online/offline detection
  onlineHandler = () => {
    if (syncStatus === 'offline') void triggerSync()
  }
  window.addEventListener('online', onlineHandler)

  offlineHandler = () => {
    syncStatus = 'offline'
    notifyListeners()
  }
  window.addEventListener('offline', offlineHandler)
```

Replace the entire block with a single subscription:

```ts
  // Online/offline detection — single subscription via the Connectivity service
  connectivityUnsubscribe = getConnectivityService().subscribe((online) => {
    if (online) {
      if (syncStatus === 'offline') void triggerSync()
    } else {
      syncStatus = 'offline'
      notifyListeners()
    }
  })
```

- [ ] **Step 5: Replace the `navigator.onLine` check inside the periodic interval**

Find around line 160:

```ts
  // Periodic sync every 5 minutes
  intervalId = setInterval(() => {
    if (navigator.onLine) {
      void triggerSync()
    }
  }, SYNC_INTERVAL_MS)
```

Replace `navigator.onLine` with `getConnectivityService().isOnline()`:

```ts
  // Periodic sync every 5 minutes
  intervalId = setInterval(() => {
    if (getConnectivityService().isOnline()) {
      void triggerSync()
    }
  }, SYNC_INTERVAL_MS)
```

- [ ] **Step 6: Replace the teardown logic in `destroyDesktopSync`**

Find around lines 177–185:

```ts
  if (onlineHandler) {
    window.removeEventListener('online', onlineHandler)
    onlineHandler = null
  }
  if (offlineHandler) {
    window.removeEventListener('offline', offlineHandler)
    offlineHandler = null
  }
```

Replace the entire block with a single unsubscribe:

```ts
  if (connectivityUnsubscribe) {
    connectivityUnsubscribe()
    connectivityUnsubscribe = null
  }
```

- [ ] **Step 7: Sanity-check `navigator.onLine` is fully gone from this file**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
grep -n "navigator.onLine\|addEventListener.*online\|addEventListener.*offline" src/renderer/src/modules/sync-triggers.ts
```

Expected: zero matches.

- [ ] **Step 8: Verify the file typechecks and connectivity tests still pass**

```bash
pnpm typecheck 2>&1 | grep sync-triggers | head -5
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: no new errors in `sync-triggers.ts`; 7 tests pass.

- [ ] **Step 9: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/modules/sync-triggers.ts
git commit -m "refactor(connectivity): migrate sync-triggers off raw navigator.onLine

Consolidates 3 navigator.onLine reads + 2 window event listeners into
one getConnectivityService().subscribe() call. Subtle correctness win:
duplicate browser events are now debounced by the service's transition
guard, where previously they could double-fire notifyListeners()."
```

---

## Task 12: Migrate `NetworkBanner.tsx`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/NetworkBanner.tsx`

- [ ] **Step 1: Change the hook import path**

Open `apps/rishi-electron/src/renderer/src/components/NetworkBanner.tsx`. Find:

```ts
import { useIsOnline } from '@/hooks/useConnectivity'
```

Replace with:

```ts
import { useIsOnline } from '@/services'
```

No other changes to this file. The hook's return shape (`boolean`) is identical.

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck 2>&1 | grep NetworkBanner | head -5
pnpm vitest run src/renderer/src/services/connectivity/service.test.ts
```

Expected: no new errors; 7 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/components/NetworkBanner.tsx
git commit -m "refactor(connectivity): migrate NetworkBanner to service-exported useIsOnline"
```

---

## Task 13: Delete dead code

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/modules/connectivity.ts`
- Delete: `apps/rishi-electron/src/renderer/src/machines/connectivityMachine.ts`
- Delete: `apps/rishi-electron/src/renderer/src/machines/__tests__/connectivityMachine.test.ts`
- Delete: `apps/rishi-electron/src/renderer/src/hooks/useConnectivity.ts`

- [ ] **Step 1: Confirm no remaining references**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
grep -rn "from '@/modules/connectivity'\|from '@/machines/connectivityMachine'\|from '@/hooks/useConnectivity'\|connectivityActor" src/ 2>/dev/null
```

Expected: zero matches. If any remain, that caller wasn't migrated — return to Task 10 / 11 / 12 to finish.

- [ ] **Step 2: Delete the four files**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
rm apps/rishi-electron/src/renderer/src/modules/connectivity.ts
rm apps/rishi-electron/src/renderer/src/machines/connectivityMachine.ts
rm apps/rishi-electron/src/renderer/src/machines/__tests__/connectivityMachine.test.ts
rm apps/rishi-electron/src/renderer/src/hooks/useConnectivity.ts
```

- [ ] **Step 3: Verify typecheck + tests**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck 2>&1 | grep -E "connectivity|machines|hooks/useConnectivity" | head -10
pnpm test 2>&1 | tail -5
```

Expected:
- Typecheck: no new errors specifically about the deleted files (existing pre-existing failures in unrelated areas don't count).
- `pnpm test`: at minimum, the connectivity service tests and adjacent test files pass. Pre-existing native-module failures in `src/main/database/__tests__/` are unchanged from baseline — not a regression.

If anything points at the deleted files and fails, investigate (likely a missed caller).

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add -A apps/rishi-electron/src/renderer/src/modules/connectivity.ts \
           apps/rishi-electron/src/renderer/src/machines/connectivityMachine.ts \
           apps/rishi-electron/src/renderer/src/machines/__tests__/connectivityMachine.test.ts \
           apps/rishi-electron/src/renderer/src/hooks/useConnectivity.ts
git commit -m "refactor(connectivity): delete xstate machine, singleton actor, and old hook

All callers now use getConnectivityService() / useIsOnline() from
@/services. The xstate machine, its singleton actor, the corresponding
machine test, and the renderer/src/hooks/useConnectivity.ts hook are
no longer used."
```

(The `git add -A <paths>` form stages deletions explicitly by path. If the directory `machines/__tests__/` becomes empty after this deletion and you want to keep it, leave it; if it has other tests, ignore.)

---

## Task 14: Final verification + PR

**Files:** none (verification only).

- [ ] **Step 1: Run typecheck, lint, and tests across the app**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
pnpm lint
pnpm test
```

Expected: pre-existing failures (e.g., `better-sqlite3` native ABI in `src/main/database/__tests__/`, ESLint issues in unrelated files) are unchanged from baseline. Any NEW failure introduced by this branch must be investigated and fixed in a new commit.

- [ ] **Step 2: Confirm zero raw `navigator.onLine` references remain in the renderer src**

```bash
grep -rn "navigator.onLine" src/renderer/ 2>/dev/null
```

Expected: zero matches.

- [ ] **Step 3: Sanity-check the new service is the only path to "are we online?"**

```bash
grep -rn "createConnectivityService\|getConnectivityService" src/ | head -20
```

Expected: matches only in `services/connectivity/service.ts` (definition), `services/connectivity/index.ts` (re-export), `services/connectivity/useIsOnline.ts` (hook), `services/index.ts` (wiring), `services/connectivity/service.test.ts` (tests), `modules/voiceChatService.ts` (caller), `modules/sync-triggers.ts` (caller). No other consumers.

- [ ] **Step 4: Push the branch and open the PR**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git push -u origin refactor/connectivity-service
gh pr create --title "refactor(connectivity): unify online-detection behind a single service" --body "$(cat <<'EOF'
## Summary
- New \`ConnectivityService\` at \`apps/rishi-electron/src/renderer/src/services/connectivity/\` is the single source of truth for online/offline state.
- Two methods (\`isOnline\`, \`subscribe\`) + one React hook (\`useIsOnline\`).
- Three callers migrated: \`voiceChatService\`, \`sync-triggers\`, \`NetworkBanner\`. After this PR, zero raw \`navigator.onLine\` reads remain in the renderer.
- xstate machine dropped: it was 16 LOC of ceremony for 2 states / 2 events. Replaced by a 30-LOC plain-TS observer pattern.
- 6 boundary tests using a hand-rolled \`createFakeSource\` adapter; no jsdom / window globals needed at test time.
- TDD throughout — red → green → commit per behavior.

Spec: \`docs/superpowers/specs/2026-05-11-connectivity-service-design.md\`
Meta-spec: \`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md\` (Wave 1, service 2 of 6)

## Behavioral notes worth flagging
- **Subtle correctness win in sync-triggers:** duplicate browser \`online\`/\`offline\` events are now debounced by the service's transition guard. The previous raw \`window.addEventListener\` flow could fire \`notifyListeners()\` on spurious duplicate events; the new flow can't.
- **Initial-state contract:** \`subscribe\`'s listener fires only on transitions, not on subscribe. Callers needing the initial value at subscribe time call \`isOnline()\` first.

## Test plan
- [ ] \`pnpm typecheck\` — pre-existing failures unchanged; no new failures.
- [ ] \`pnpm lint\` — pre-existing warnings unchanged; no new errors.
- [ ] \`pnpm test\` — connectivity service tests pass; pre-existing failures unchanged.
- [ ] Manual: simulate offline via Chrome DevTools Network panel; verify \`NetworkBanner\` shows; verify voice chat tears down; verify sync status flips to 'offline'.
- [ ] Manual: simulate online again; verify banner hides; verify voice chat can be restarted; verify sync triggers automatically.

## Latent risks worth knowing
- \`getConnectivityService()\` memoizes in module scope; tests that import \`@/services\` without mocking will share the instance. Current tests avoid this by passing \`createFakeSource()\` directly to \`createConnectivityService\`.
- The service reads \`window\` lazily at first call. Won't work outside a renderer context (SSR, Node tests without happy-dom) — but no caller exercises that path today.
EOF
)"
```

---

## Summary

After all tasks complete:
- 14 commits on `refactor/connectivity-service` branch.
- Net diff (approximate): +200 lines added (service + tests + hook + wiring), -80 lines removed (4 deleted files + caller cleanups).
- All 6 boundary tests in the spec (split into 7 `it()` blocks because Test 1 has two cases) are green at the public interface.
- xstate eliminated from connectivity entirely.
- Public interface of the service exactly matches the spec.
- Zero raw `navigator.onLine` reads remain in the renderer src.
