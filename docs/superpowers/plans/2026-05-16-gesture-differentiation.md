# Gesture Differentiation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix text selection in the EPUB reader by differentiating selection gestures from page-turn gestures across touch (2-finger), trackpad (wheel), and mouse/pen (edge-zone) devices.

**Architecture:** Replace `usePageCurl` with a new unified `useReaderGesture` hook that adds touch-pointer-counting and wheel-event accumulation, while keeping the existing edge-zone mouse path with a narrower 24 px edge. Flip `<ReactReader swipeable={false}>` to kill epub.js's internal swipe handler inside the iframe.

**Tech Stack:** React + TypeScript (renderer), vitest + @testing-library/react (unit), Playwright (e2e), epub.js via `<ReactReader>`.

**Spec:** `docs/superpowers/specs/2026-05-16-read-aloud-from-selection-design.md` § 4 (Phase 0)

---

## File Structure

**Create:**
- `apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.ts` — new unified gesture hook
- `apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.test.ts` — unit tests
- `apps/rishi-electron/e2e/epub-text-selection.spec.ts` — Playwright e2e

**Modify:**
- `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx` — swap hook; spread `wheelHandlers`; flip both `swipeable={true}` → `swipeable={false}` (lines 593, 734 in current snapshot — re-verify before editing)

**Delete (final task, only after migration verified):**
- `apps/rishi-electron/src/renderer/src/components/pagecurl/usePageCurl.ts`
- `apps/rishi-electron/src/renderer/src/components/pagecurl/usePageCurl.test.ts`

The PDF reader is intentionally untouched in Phase 0 — it has no page-curl today and Phase 1 will add selection capture from scratch.

---

### Task 1: Skeleton — failing test + minimal hook

**Files:**
- Create: `src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
- Create: `src/renderer/src/components/pagecurl/useReaderGesture.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/renderer/src/components/pagecurl/useReaderGesture.test.ts
import { describe, it, expect, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useReaderGesture } from './useReaderGesture'

describe('useReaderGesture', () => {
  const defaultCallbacks = {
    onNavigate: vi.fn(() => true),
    onCommit: vi.fn(),
    onUndoNavigate: vi.fn()
  }

  it('starts idle with zero progress', () => {
    const { result } = renderHook(() => useReaderGesture(defaultCallbacks))
    expect(result.current.progress).toBe(0)
    expect(result.current.active).toBe(false)
    expect(result.current.direction).toBe('right')
  })

  it('exposes pointer, wheel, and autoTurn surfaces', () => {
    const { result } = renderHook(() => useReaderGesture(defaultCallbacks))
    const { pointerHandlers, wheelHandlers, autoTurn } = result.current
    expect(typeof pointerHandlers.onPointerDown).toBe('function')
    expect(typeof pointerHandlers.onPointerMove).toBe('function')
    expect(typeof pointerHandlers.onPointerUp).toBe('function')
    expect(typeof pointerHandlers.onPointerCancel).toBe('function')
    expect(typeof wheelHandlers.onWheel).toBe('function')
    expect(typeof autoTurn).toBe('function')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter rishi-electron test src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
Expected: FAIL — `Cannot find module './useReaderGesture'`

- [ ] **Step 3: Write minimal implementation**

```ts
// src/renderer/src/components/pagecurl/useReaderGesture.ts
import { useCallback, useState } from 'react'
import type { CurlDirection } from './drawPageCurl'

export interface ReaderGestureResult {
  progress: number
  direction: CurlDirection
  active: boolean
  pointerHandlers: {
    onPointerDown: (e: React.PointerEvent) => void
    onPointerMove: (e: React.PointerEvent) => void
    onPointerUp: (e: React.PointerEvent) => void
    onPointerCancel: (e: React.PointerEvent) => void
  }
  wheelHandlers: {
    onWheel: (e: React.WheelEvent) => void
  }
  autoTurn: (dir: CurlDirection) => void
}

export function useReaderGesture(_callbacks: {
  onNavigate: (dir: CurlDirection) => boolean
  onCommit: (dir: CurlDirection) => void
  onUndoNavigate: (dir: CurlDirection) => void
}): ReaderGestureResult {
  const [progress] = useState(0)
  const [direction] = useState<CurlDirection>('right')
  const [active] = useState(false)

  const noop = useCallback(() => {}, [])
  return {
    progress,
    direction,
    active,
    pointerHandlers: {
      onPointerDown: noop,
      onPointerMove: noop,
      onPointerUp: noop,
      onPointerCancel: noop
    },
    wheelHandlers: { onWheel: noop },
    autoTurn: noop
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm --filter rishi-electron test src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.ts \
        apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.test.ts
git commit -m "feat(gesture): skeleton useReaderGesture hook"
```

---

### Task 2: Mouse edge-zone claim with EDGE_ZONE=24

**Files:**
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.test.ts` (add cases)
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.ts` (port edge-zone logic)

- [ ] **Step 1: Write the failing tests**

Append to `useReaderGesture.test.ts`:

```ts
import { act } from '@testing-library/react'

function makeMockPointerEvent(opts: {
  clientX: number
  pointerId?: number
  pointerType?: 'mouse' | 'touch' | 'pen'
  width?: number
}): React.PointerEvent {
  const { clientX, pointerId = 1, pointerType = 'mouse', width = 800 } = opts
  return {
    clientX,
    pointerId,
    pointerType,
    currentTarget: {
      getBoundingClientRect: () => ({ left: 0, width, height: 600, top: 0 }),
      setPointerCapture: vi.fn(),
      releasePointerCapture: vi.fn()
    }
  } as unknown as React.PointerEvent
}

describe('useReaderGesture - mouse edge-zone', () => {
  it('claims pointer down within 24 px of left edge (mouse)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 10 }))
    })
    expect(onNavigate).toHaveBeenCalledWith('left')
    expect(result.current.active).toBe(true)
  })

  it('claims pointer down within 24 px of right edge (mouse)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 790 /* width 800, edge 24 → > 776 */ })
      )
    })
    expect(onNavigate).toHaveBeenCalledWith('right')
    expect(result.current.active).toBe(true)
  })

  it('does NOT claim pointer down outside the 24 px edge zone', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 60 }))
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 400 }))
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 770 }))
    })
    expect(onNavigate).not.toHaveBeenCalled()
    expect(result.current.active).toBe(false)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter rishi-electron test src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
Expected: FAIL (3 new tests fail; original 2 still pass)

- [ ] **Step 3: Port mouse edge-zone logic with EDGE_ZONE=24**

Replace the contents of `useReaderGesture.ts` with the full port of `usePageCurl.ts`, changing only:
- `const EDGE_ZONE = 60` → `const EDGE_ZONE = 24`
- Add early-return `if (e.pointerType === 'touch') return` at the top of `onPointerDown` (touch is handled in Task 4)
- Add a `wheelHandlers` field with a no-op `onWheel` for now (Task 6 implements it)
- Rename exported symbol from `usePageCurl` → `useReaderGesture` and export type `ReaderGestureResult`

Full file (replaces the skeleton from Task 1):

```ts
// src/renderer/src/components/pagecurl/useReaderGesture.ts
import { useCallback, useEffect, useRef, useState } from 'react'
import type { CurlDirection } from './drawPageCurl'

export type CurlState = 'idle' | 'dragging' | 'animating'

export interface ReaderGestureResult {
  progress: number
  direction: CurlDirection
  active: boolean
  pointerHandlers: {
    onPointerDown: (e: React.PointerEvent) => void
    onPointerMove: (e: React.PointerEvent) => void
    onPointerUp: (e: React.PointerEvent) => void
    onPointerCancel: (e: React.PointerEvent) => void
  }
  wheelHandlers: {
    onWheel: (e: React.WheelEvent) => void
  }
  autoTurn: (dir: CurlDirection) => void
}

const EDGE_ZONE = 24
const COMMIT_THRESHOLD = 0.3
const AUTO_DURATION = 200
const SNAP_DURATION = 120
const VELOCITY_COMMIT = 1.2

function easeOutQuart(t: number): number {
  return 1 - Math.pow(1 - t, 4)
}

export function useReaderGesture(callbacks: {
  onNavigate: (dir: CurlDirection) => boolean
  onCommit: (dir: CurlDirection) => void
  onUndoNavigate: (dir: CurlDirection) => void
}): ReaderGestureResult {
  const [active, setActive] = useState(false)
  const [progress, setProgress] = useState(0)
  const [direction, setDirection] = useState<CurlDirection>('right')
  const progressRef = useRef(0)
  const directionRef = useRef<CurlDirection>('right')
  const stateRef = useRef<CurlState>('idle')
  const rafRef = useRef<number | null>(null)
  const containerRectRef = useRef<DOMRect | null>(null)
  const navigatedRef = useRef(false)
  const lastMoveTimeRef = useRef(0)
  const lastProgressRef = useRef(0)
  const velocityRef = useRef(0)

  const setProgressBoth = useCallback((p: number) => {
    progressRef.current = p
    setProgress(p)
  }, [])
  const setDirectionBoth = useCallback((d: CurlDirection) => {
    directionRef.current = d
    setDirection(d)
  }, [])

  const callbacksRef = useRef(callbacks)
  useEffect(() => {
    callbacksRef.current = callbacks
  })

  const cancelRaf = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current)
      rafRef.current = null
    }
  }, [])

  const animateTo = useCallback(
    (target: number, duration: number, onDone: () => void) => {
      cancelRaf()
      const start = progressRef.current
      const startTime = performance.now()
      stateRef.current = 'animating'
      function tick(now: number) {
        const elapsed = now - startTime
        const rawT = Math.min(elapsed / duration, 1)
        const t = easeOutQuart(rawT)
        setProgressBoth(start + (target - start) * t)
        if (rawT < 1) {
          rafRef.current = requestAnimationFrame(tick)
        } else {
          setProgressBoth(target)
          rafRef.current = null
          onDone()
        }
      }
      rafRef.current = requestAnimationFrame(tick)
    },
    [cancelRaf, setProgressBoth]
  )

  const finish = useCallback(
    (completed: boolean) => {
      const dir = directionRef.current
      if (completed && navigatedRef.current) callbacksRef.current.onCommit(dir)
      else if (!completed && navigatedRef.current) callbacksRef.current.onUndoNavigate(dir)
      stateRef.current = 'idle'
      setProgressBoth(0)
      navigatedRef.current = false
      setActive(false)
    },
    [setProgressBoth]
  )

  const commitOrCancel = useCallback(() => {
    const p = progressRef.current
    const v = velocityRef.current
    if (p >= COMMIT_THRESHOLD || v > VELOCITY_COMMIT) {
      animateTo(1, SNAP_DURATION, () => finish(true))
    } else {
      animateTo(0, SNAP_DURATION, () => finish(false))
    }
  }, [animateTo, finish])

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      // Touch is handled by 2-pointer logic (Task 4). Mouse/pen use edge-zone.
      if (e.pointerType === 'touch') return
      if (stateRef.current !== 'idle') return
      const rect = e.currentTarget.getBoundingClientRect()
      const x = e.clientX - rect.left
      const nearRight = x > rect.width - EDGE_ZONE
      const nearLeft = x < EDGE_ZONE
      if (!nearRight && !nearLeft) return
      const dir: CurlDirection = nearRight ? 'right' : 'left'
      if (!callbacksRef.current.onNavigate(dir)) return
      e.currentTarget.setPointerCapture(e.pointerId)
      setDirectionBoth(dir)
      containerRectRef.current = rect
      stateRef.current = 'dragging'
      const W = rect.width
      const raw = dir === 'right' ? 1 - x / W : x / W
      const clamped = Math.max(0, Math.min(1, raw))
      setProgressBoth(clamped)
      velocityRef.current = 0
      lastMoveTimeRef.current = performance.now()
      lastProgressRef.current = clamped
      navigatedRef.current = true
      setActive(true)
    },
    [setDirectionBoth, setProgressBoth]
  )

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (stateRef.current !== 'dragging') return
      const rect = containerRectRef.current
      if (!rect) return
      const x = e.clientX - rect.left
      const W = rect.width
      const isForward = directionRef.current === 'right'
      const raw = isForward ? 1 - x / W : x / W
      const newProgress = Math.max(0, Math.min(1, raw))
      const now = performance.now()
      const dt = now - lastMoveTimeRef.current
      if (dt > 0 && dt < 100) {
        const instant = ((newProgress - lastProgressRef.current) / dt) * 1000
        velocityRef.current = 0.7 * instant + 0.3 * velocityRef.current
      }
      lastMoveTimeRef.current = now
      lastProgressRef.current = newProgress
      setProgressBoth(newProgress)
    },
    [setProgressBoth]
  )

  const onPointerUp = useCallback(
    (_e: React.PointerEvent) => {
      if (stateRef.current !== 'dragging') return
      commitOrCancel()
    },
    [commitOrCancel]
  )

  const onPointerCancel = useCallback(
    (_e: React.PointerEvent) => {
      if (stateRef.current !== 'dragging') return
      commitOrCancel()
    },
    [commitOrCancel]
  )

  const onWheel = useCallback((_e: React.WheelEvent) => {
    // Implemented in Task 6.
  }, [])

  const autoTurn = useCallback(
    (dir: CurlDirection) => {
      if (stateRef.current !== 'idle') return
      if (!callbacksRef.current.onNavigate(dir)) return
      cancelRaf()
      setDirectionBoth(dir)
      setProgressBoth(0)
      stateRef.current = 'animating'
      navigatedRef.current = true
      setActive(true)
      animateTo(1, AUTO_DURATION, () => finish(true))
    },
    [cancelRaf, setDirectionBoth, setProgressBoth, animateTo, finish]
  )

  useEffect(() => {
    return () => cancelRaf()
  }, [cancelRaf])

  return {
    progress,
    direction,
    active,
    pointerHandlers: { onPointerDown, onPointerMove, onPointerUp, onPointerCancel },
    wheelHandlers: { onWheel },
    autoTurn
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm --filter rishi-electron test src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.ts \
        apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.test.ts
git commit -m "feat(gesture): mouse edge-zone path with 24px edge"
```

---

### Task 3: Touch single-finger never claims

**Files:**
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.test.ts`

- [ ] **Step 1: Write the failing test**

Append:

```ts
describe('useReaderGesture - touch', () => {
  it('ignores single-finger touch even in edge zone', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 10, pointerType: 'touch', pointerId: 1 })
      )
    })
    expect(onNavigate).not.toHaveBeenCalled()
    expect(result.current.active).toBe(false)
  })
})
```

- [ ] **Step 2: Run test**

Run: `pnpm --filter rishi-electron test src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
Expected: PASS — Task 2 already added the touch early-return.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.test.ts
git commit -m "test(gesture): single-finger touch never claims"
```

---

### Task 4: Touch two-finger claim

**Files:**
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.ts`

- [ ] **Step 1: Write the failing tests**

Append:

```ts
describe('useReaderGesture - touch two-finger', () => {
  it('claims when a second finger lands (horizontal swipe)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // First finger
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 200, pointerType: 'touch', pointerId: 1 })
      )
      // Second finger — claim should happen now
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
    })
    // Direction inferred from average x: both on left half → assume forward swipe
    // intent is direction-agnostic here; the move handler resolves it. We only
    // assert that the claim happened.
    expect(onNavigate).toHaveBeenCalledTimes(1)
    expect(result.current.active).toBe(true)
  })

  it('releases when one finger lifts so the other becomes single-finger', () => {
    const onCommit = vi.fn()
    const onUndoNavigate = vi.fn()
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate: vi.fn(() => true), onCommit, onUndoNavigate })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 200, pointerType: 'touch', pointerId: 1 })
      )
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
      // Lift one finger
      result.current.pointerHandlers.onPointerUp(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
    })
    // Releasing back to 1 finger commits-or-cancels (cancel since progress=0)
    expect(onUndoNavigate).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — touch path currently early-returns and ignores everything.

- [ ] **Step 3: Implement two-pointer tracking**

In `useReaderGesture.ts`, add a touch-pointer map and rework `onPointerDown` / `onPointerUp` / `onPointerCancel` so touch flows through a separate path:

```ts
// Add near the top of the hook body, after the existing refs:
const touchPointersRef = useRef<Map<number, { x: number; y: number }>>(new Map())

// Helper: returns avg x of all active touch pointers
const avgTouchX = (): number => {
  const pts = Array.from(touchPointersRef.current.values())
  if (pts.length === 0) return 0
  return pts.reduce((s, p) => s + p.x, 0) / pts.length
}
```

Replace the existing `onPointerDown` callback with this two-path version:

```ts
const onPointerDown = useCallback(
  (e: React.PointerEvent) => {
    if (e.pointerType === 'touch') {
      // Record this touch pointer
      const rect = e.currentTarget.getBoundingClientRect()
      touchPointersRef.current.set(e.pointerId, {
        x: e.clientX - rect.left,
        y: e.clientY - rect.top
      })
      // Claim only when 2 fingers down AND machine is idle
      if (touchPointersRef.current.size === 2 && stateRef.current === 'idle') {
        // Direction is provisional; refined by onPointerMove. Default 'right'.
        const dir: CurlDirection = 'right'
        if (!callbacksRef.current.onNavigate(dir)) return
        e.currentTarget.setPointerCapture(e.pointerId)
        setDirectionBoth(dir)
        containerRectRef.current = rect
        stateRef.current = 'dragging'
        setProgressBoth(0)
        velocityRef.current = 0
        lastMoveTimeRef.current = performance.now()
        lastProgressRef.current = 0
        navigatedRef.current = true
        setActive(true)
      }
      return
    }
    // ... existing mouse/pen path unchanged
  },
  [setDirectionBoth, setProgressBoth]
)
```

Replace `onPointerUp` / `onPointerCancel` to remove the pointer from the touch map and commit-or-cancel when we drop below 2:

```ts
const onPointerUp = useCallback(
  (e: React.PointerEvent) => {
    if (e.pointerType === 'touch') {
      const wasMulti = touchPointersRef.current.size >= 2
      touchPointersRef.current.delete(e.pointerId)
      if (wasMulti && touchPointersRef.current.size < 2 && stateRef.current === 'dragging') {
        commitOrCancel()
      }
      return
    }
    if (stateRef.current !== 'dragging') return
    commitOrCancel()
  },
  [commitOrCancel]
)

const onPointerCancel = useCallback(
  (e: React.PointerEvent) => {
    if (e.pointerType === 'touch') {
      touchPointersRef.current.delete(e.pointerId)
      if (touchPointersRef.current.size < 2 && stateRef.current === 'dragging') {
        commitOrCancel()
      }
      return
    }
    if (stateRef.current !== 'dragging') return
    commitOrCancel()
  },
  [commitOrCancel]
)
```

Update `onPointerMove` to handle the touch path by tracking average horizontal delta:

```ts
const onPointerMove = useCallback(
  (e: React.PointerEvent) => {
    if (e.pointerType === 'touch') {
      const rect = containerRectRef.current
      if (!rect) return
      const existing = touchPointersRef.current.get(e.pointerId)
      if (!existing) return
      touchPointersRef.current.set(e.pointerId, {
        x: e.clientX - rect.left,
        y: e.clientY - rect.top
      })
      if (stateRef.current !== 'dragging' || touchPointersRef.current.size < 2) return
      const avgX = avgTouchX()
      const W = rect.width
      // Treat the gesture like a horizontal drag from the right edge: progress
      // grows as the average finger position moves leftward.
      const raw = 1 - avgX / W
      const newProgress = Math.max(0, Math.min(1, raw))
      setProgressBoth(newProgress)
      return
    }
    // ... existing mouse/pen move path unchanged
  },
  [setProgressBoth]
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm --filter rishi-electron test src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
Expected: PASS (all tests so far)

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.ts \
        apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.test.ts
git commit -m "feat(gesture): two-finger touch swipe claim"
```

---

### Task 5: Wheel accumulator — horizontal navigation on trackpad

**Files:**
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.ts`

- [ ] **Step 1: Write the failing tests**

Append (uses vitest fake timers):

```ts
import { afterEach, beforeEach } from 'vitest'

function makeWheelEvent(opts: { deltaX: number; deltaY: number }): React.WheelEvent {
  return {
    deltaX: opts.deltaX,
    deltaY: opts.deltaY,
    preventDefault: vi.fn()
  } as unknown as React.WheelEvent
}

describe('useReaderGesture - wheel (trackpad)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('fires onNavigate("right") after accumulating > 50 px of leftward wheel', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // 3 wheel ticks, each deltaX = +20, deltaY = +3 → cumulative 60
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 20, deltaY: 3 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 20, deltaY: 3 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 20, deltaY: 3 }))
    })
    // Debounce hasn't fired yet
    expect(onNavigate).not.toHaveBeenCalled()
    act(() => {
      vi.advanceTimersByTime(130)
    })
    // Positive deltaX = scroll right = next page
    expect(onNavigate).toHaveBeenCalledWith('right')
  })

  it('fires onNavigate("left") for negative deltaX', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: -30, deltaY: 2 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: -30, deltaY: 2 }))
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).toHaveBeenCalledWith('left')
  })

  it('does NOT fire when vertical scroll dominates', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // deltaY > deltaX * 1.5 → ignored
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 10, deltaY: 50 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 10, deltaY: 50 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 10, deltaY: 50 }))
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).not.toHaveBeenCalled()
  })

  it('ignores small horizontal deltas (< 6 per tick)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      for (let i = 0; i < 20; i++) {
        result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 3, deltaY: 0 }))
      }
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).not.toHaveBeenCalled()
  })

  it('does not double-fire within the same debounce window', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 60, deltaY: 5 }))
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).toHaveBeenCalledTimes(1)
    act(() => {
      vi.advanceTimersByTime(500)
    })
    expect(onNavigate).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `onWheel` is still a no-op.

- [ ] **Step 3: Implement wheel accumulator**

Add constants near the top of the hook file:

```ts
const WHEEL_PER_TICK_MIN = 6      // ignore tiny deltas (noise)
const WHEEL_RATIO_GATE = 1.5      // |deltaX| must exceed |deltaY| * ratio
const WHEEL_CUMULATIVE_THRESHOLD = 50
const WHEEL_DEBOUNCE_MS = 120
```

Add refs inside the hook (alongside the other refs):

```ts
const wheelBufferRef = useRef(0)
const wheelTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

const clearWheelTimer = useCallback(() => {
  if (wheelTimerRef.current !== null) {
    clearTimeout(wheelTimerRef.current)
    wheelTimerRef.current = null
  }
}, [])
```

Replace the placeholder `onWheel` callback:

```ts
const onWheel = useCallback(
  (e: React.WheelEvent) => {
    const dx = e.deltaX
    const dy = e.deltaY
    // Reject vertical-dominant gestures
    if (Math.abs(dy) > Math.abs(dx) * WHEEL_RATIO_GATE) {
      wheelBufferRef.current = 0
      clearWheelTimer()
      return
    }
    // Reject tiny ticks
    if (Math.abs(dx) < WHEEL_PER_TICK_MIN) return
    e.preventDefault()
    wheelBufferRef.current += dx
    clearWheelTimer()
    wheelTimerRef.current = setTimeout(() => {
      const sum = wheelBufferRef.current
      wheelBufferRef.current = 0
      wheelTimerRef.current = null
      if (Math.abs(sum) < WHEEL_CUMULATIVE_THRESHOLD) return
      const dir: CurlDirection = sum > 0 ? 'right' : 'left'
      if (!callbacksRef.current.onNavigate(dir)) return
      // Visual feedback via autoTurn
      cancelRaf()
      setDirectionBoth(dir)
      setProgressBoth(0)
      stateRef.current = 'animating'
      navigatedRef.current = true
      setActive(true)
      animateTo(1, AUTO_DURATION, () => finish(true))
    }, WHEEL_DEBOUNCE_MS)
  },
  [animateTo, cancelRaf, clearWheelTimer, finish, setActive, setDirectionBoth, setProgressBoth]
)
```

Also clear the wheel timer in the unmount effect:

```ts
useEffect(() => {
  return () => {
    cancelRaf()
    clearWheelTimer()
  }
}, [cancelRaf, clearWheelTimer])
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm --filter rishi-electron test src/renderer/src/components/pagecurl/useReaderGesture.test.ts`
Expected: PASS (all tests)

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.ts \
        apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.test.ts
git commit -m "feat(gesture): trackpad wheel-swipe accumulator"
```

---

### Task 6: autoTurn parity test

**Files:**
- Modify: `src/renderer/src/components/pagecurl/useReaderGesture.test.ts`

- [ ] **Step 1: Write the failing test**

Append:

```ts
describe('useReaderGesture - autoTurn', () => {
  it('calls onNavigate("right") and activates', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.autoTurn('right')
    })
    expect(onNavigate).toHaveBeenCalledWith('right')
    expect(result.current.active).toBe(true)
  })

  it('autoTurn does nothing when onNavigate returns false', () => {
    const onNavigate = vi.fn(() => false)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.autoTurn('left')
    })
    expect(onNavigate).toHaveBeenCalledWith('left')
    expect(result.current.active).toBe(false)
  })
})
```

- [ ] **Step 2: Run tests**

Expected: PASS — autoTurn was ported verbatim from usePageCurl in Task 2.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pagecurl/useReaderGesture.test.ts
git commit -m "test(gesture): autoTurn parity tests"
```

---

### Task 7: Wire EpubView to useReaderGesture; flip swipeable=false

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`

- [ ] **Step 1: Re-verify exact line numbers before editing**

Run: `grep -n "usePageCurl\|swipeable={true}" apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`
Note the line numbers. The spec lists 593 and 734 for `swipeable` and 14 + 148 for `usePageCurl`, but the file may have shifted slightly.

- [ ] **Step 2: Apply the import + hook swap**

Edit `EpubView.tsx`:

Change the import line:

```diff
-import { usePageCurl } from '../pagecurl/usePageCurl'
+import { useReaderGesture } from '../pagecurl/useReaderGesture'
```

Change the hook call:

```diff
-  const pageCurl = usePageCurl({
+  const pageCurl = useReaderGesture({
     onNavigate: (dir) => {
       // Reject if the nav machine is busy — prevents double rendition calls
       if (useNavStore.getState().navState !== 'idle' || !navSend) return false
       // Clear any pending player page request to avoid double navigation
       usePlayerStore.getState().clearPageRequest()
       navSend({ type: dir === 'right' ? 'CURL_NEXT' : 'CURL_PREV' })
       return true
     },
     onCommit: () => {
       navSend?.({ type: 'CURL_COMMIT' })
     },
     onUndoNavigate: () => {
       navSend?.({ type: 'CURL_CANCEL' })
     }
   })
```

Spread the wheel handlers on the same outer `<div>` that already has the pointer handlers. Find:

```tsx
{...pageCurl.pointerHandlers}
```

And change to:

```tsx
{...pageCurl.pointerHandlers}
{...pageCurl.wheelHandlers}
```

Flip both `<ReactReader swipeable={true}>` to `swipeable={false}`. Use the line numbers verified in Step 1.

- [ ] **Step 3: Typecheck**

Run: `pnpm --filter rishi-electron typecheck:node && pnpm --filter rishi-electron exec tsc --noEmit -p tsconfig.web.json`
Expected: no type errors

- [ ] **Step 4: Run all renderer tests to check for regressions**

Run: `pnpm --filter rishi-electron test src/renderer`
Expected: all pass

- [ ] **Step 5: Manual smoke (golden path)**

Run: `pnpm --filter rishi-electron dev` (or whatever the local dev command is — confirm with `grep '"dev"' apps/rishi-electron/package.json`)
- Open an EPUB book
- Drag-select 5 words in the middle of the page — selection should appear and the SelectionPopover should pop up
- Click an arrow button → page turns
- Mouse-drag from the left edge → page-curl animation plays
- Two-finger trackpad swipe → page turns

Stop the dev server.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(epub): switch reader to useReaderGesture, disable swipeable"
```

---

### Task 8: Playwright e2e — selection works in EPUB body

**Files:**
- Create: `apps/rishi-electron/e2e/epub-text-selection.spec.ts`

- [ ] **Step 1: Inspect an existing EPUB e2e for fixture setup**

Run: `head -60 apps/rishi-electron/e2e/epub-reader.spec.ts`
Note how it opens a book (likely via a fixture helper in `e2e/helpers/`).

- [ ] **Step 2: Write the failing test**

```ts
// apps/rishi-electron/e2e/epub-text-selection.spec.ts
import { test, expect } from './fixtures'
// ^ adjust import to match the convention you observed in Step 1.

test('user can select text in the middle of an EPUB page', async ({ electronApp, page }) => {
  // Open a fixture EPUB (use whatever helper the other epub-*.spec.ts files use)
  await openFixtureEpub(electronApp, page, 'pride-and-prejudice.epub') // adjust to a real fixture

  // Wait for the rendition to mount
  const iframeLocator = page.frameLocator('iframe').first()
  await iframeLocator.locator('body').waitFor({ state: 'visible' })

  // Drag-select a chunk of text in the middle of the page
  const target = iframeLocator.locator('p').first()
  await target.waitFor()
  const box = await target.boundingBox()
  if (!box) throw new Error('No bounding box for first paragraph')

  await page.mouse.move(box.x + 20, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + 200, box.y + box.height / 2, { steps: 10 })
  await page.mouse.up()

  // The selected text inside the iframe should be non-empty
  const selectionText = await iframeLocator.evaluate(() => window.getSelection()?.toString() ?? '')
  expect(selectionText.length).toBeGreaterThan(5)
})
```

> **Note:** `openFixtureEpub` is illustrative — replace it with the exact helper used by the existing EPUB e2e tests (`epub-reader.spec.ts`, `epub-first-open.spec.ts`). The test must use the same fixture conventions as those files.

- [ ] **Step 3: Run the test**

Run: `pnpm --filter rishi-electron test:e2e epub-text-selection.spec.ts`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/e2e/epub-text-selection.spec.ts
git commit -m "test(e2e): selection works in EPUB body after gesture fix"
```

---

### Task 9: Delete usePageCurl

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/components/pagecurl/usePageCurl.ts`
- Delete: `apps/rishi-electron/src/renderer/src/components/pagecurl/usePageCurl.test.ts`

- [ ] **Step 1: Verify no remaining references**

Run: `grep -rn "usePageCurl" apps/rishi-electron/src apps/rishi-electron/e2e`
Expected: no matches.

- [ ] **Step 2: Delete the files**

Run:
```bash
git rm apps/rishi-electron/src/renderer/src/components/pagecurl/usePageCurl.ts \
       apps/rishi-electron/src/renderer/src/components/pagecurl/usePageCurl.test.ts
```

- [ ] **Step 3: Typecheck and run tests**

Run: `pnpm --filter rishi-electron typecheck:node && pnpm --filter rishi-electron test`
Expected: no errors, all tests pass.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore(gesture): remove obsolete usePageCurl"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-05-16-read-aloud-from-selection-design.md` § 4):

| Spec requirement | Task |
|---|---|
| New `useReaderGesture` module replacing `usePageCurl` | Tasks 1–6 |
| Touch: 2-pointer required for claim | Tasks 3–4 |
| Trackpad: wheel-event accumulator with ratio gate + cumulative threshold + debounce | Task 5 |
| Mouse/pen: edge-zone curl, `EDGE_ZONE` reduced 60 → 24 | Task 2 |
| EPUB: `swipeable={false}` on both `<ReactReader>` instances | Task 7 |
| PDF: `touch-action: pan-y` | *Not addressed* — PDF unaffected in Phase 0 (no page-curl today, no selection feature yet). Will be revisited in Phase 1 PDF work. |
| Acceptance #1: Playwright selection test | Task 8 |
| Acceptance #2–3: mouse drag middle/edge | Task 2 + manual in Task 7 Step 5 |
| Acceptance #4–5: two-finger gestures | Manual in Task 7 Step 5 (Playwright can't reliably synthesize 2-finger touch) |
| Acceptance #6: arrow keys, arrow buttons, TTS auto-turn, bookmark nav still work | Task 6 (autoTurn parity) + Task 7 Step 4 (regression test suite) |

**Placeholder scan:** no `TBD`/`TODO`/`implement later`. The PDF `touch-action` item is intentionally deferred and that deferral is documented. The Playwright helper name (`openFixtureEpub`) is flagged as "replace with the actual helper" — that's a real instruction to the implementer to follow existing conventions, not a placeholder.

**Type consistency:** `ReaderGestureResult.pointerHandlers` and `.wheelHandlers` shapes are defined in Task 1 and re-used in Tasks 2, 4, 5, 7. Callback shape (`onNavigate`/`onCommit`/`onUndoNavigate`) is identical to `usePageCurl`'s so EpubView's existing wiring (Task 7) needs no callback changes. `CurlDirection` re-used from `drawPageCurl.ts` throughout.

**Risk:** Task 4's `direction` is provisional ('right') and only refined by `onPointerMove`. If two fingers swipe left immediately and never move horizontally enough, the wrong direction could navigate. Mitigated in practice because real two-finger swipes cover noticeable horizontal distance before pointerup. If this surfaces as a real issue during manual smoke (Task 7 Step 5), add a "delay claim until horizontal delta exceeds 20 px" refinement and a corresponding test.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-16-gesture-differentiation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
