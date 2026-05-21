# Reader Navigation History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a back-stack with floating pill affordance for deliberate in-book jumps (links, TOC, bookmarks, search) AND a smart per-page resume that restores scroll/TTS position when the user returns to a page they previously engaged with.

**Architecture:** One XState v5 machine (`navigationHistoryMachine`) with three parallel regions (`stack`, `engagement`, `pill`). React layer uses `@xstate/react` `useSelector` for subscriptions; a thin send-only Zustand wrapper handles the EPUB iframe handler that runs outside React context. Per-format link interceptors funnel into one `JUMP_REQUESTED` event. Engagement signals (tap, 20s dwell, TTS playback) trigger per-page resume capture.

**Tech Stack:** TypeScript, XState v5.30.0 (`setup().createMachine()` pattern), `@xstate/react` (new dependency), Zustand, React 18, Vitest + @testing-library/react. Spec: `docs/superpowers/specs/2026-05-21-reader-navigation-history-design.md`.

**Working dir for all tasks:** `apps/rishi-electron`
**Test command:** `pnpm test` (vitest run; uses `npm test` script under the hood)
**Path alias:** `@/` → `src/renderer/src/`

---

## File Inventory

### New files
- `src/renderer/src/machines/navigationHistory/types.ts` — `PositionDescriptor`, `AnchorPoint`, `TtsContext`, `Context`, event union
- `src/renderer/src/machines/navigationHistory/pageKey.ts` — `pageKey()` helper + `pageKey.test.ts`
- `src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts` + `.test.ts`
- `src/renderer/src/machines/navigationHistory/navigationHistoryActor.ts` — singleton actor + send-only Zustand wrapper
- `src/renderer/src/hooks/useNavigationHistory.ts` — convenience selectors for components
- `src/renderer/src/hooks/useEngagementDetector.ts` + `.test.tsx`
- `src/renderer/src/components/navigation-history/NavigationHistoryFooter.tsx` + `.test.tsx`

### Modified files
- `package.json` — add `@xstate/react`
- `src/renderer/src/components/react-reader/epub_viewer/index.tsx` — register iframe click listener for body link interception
- `src/renderer/src/components/epub/EpubView.tsx` — wrap `setLocation` callsite (TOC/bookmark/search); mount footer; lifecycle events
- `src/renderer/src/components/pdf/components/pdf-page.tsx` — annotation click interception
- `src/renderer/src/components/pdf/components/pdf.tsx` — wrap TOC `onItemClick`; mount footer; lifecycle events
- `src/renderer/src/components/azw3/Azw3View.tsx` — link interception (uses epub.js-like rendition or DOM); mount footer; lifecycle events
- (No changes to `routes/books.$id.lazy.tsx` — each format view owns its own lifecycle dispatch)

---

## Phase 1 — Core types and pageKey helper

### Task 1: Define types module

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/types.ts`

- [ ] **Step 1: Write the types file**

```typescript
// apps/rishi-electron/src/renderer/src/machines/navigationHistory/types.ts

export type PositionDescriptor =
  | { kind: 'pdf'; page: number; offset: number }
  | { kind: 'epub'; cfi: string }
  | { kind: 'azw3'; cfi: string }
  | { kind: 'mobi'; cfi: string }

export type TtsContext = {
  paragraphIndex: number
} | null

export type JumpSource = 'link' | 'toc' | 'bookmark' | 'search' | 'engagement'

export type AnchorPoint = {
  id: string
  bookId: string
  position: PositionDescriptor
  tts: TtsContext
  label: string
  capturedAt: number
  source: JumpSource
}

export type NavigationHistoryContext = {
  bookId: string | null
  stack: AnchorPoint[]
  resumeMap: Map<string, AnchorPoint>
  currentPage: PositionDescriptor | null
  pillVisible: boolean
}

export type NavigationHistoryEvent =
  | { type: 'BOOK_OPENED'; bookId: string; initialPosition: PositionDescriptor }
  | { type: 'BOOK_CLOSED' }
  | { type: 'PAGE_VISITED'; position: PositionDescriptor; ttsContext: TtsContext }
  | {
      type: 'JUMP_REQUESTED'
      from: PositionDescriptor
      fromTts: TtsContext
      to: PositionDescriptor
      source: JumpSource
      fromLabel: string
    }
  | { type: 'POP_BACK' }
  | { type: 'DISMISS_PILL' }
  | { type: 'ENGAGEMENT_TAP' }
  | { type: 'ENGAGEMENT_TTS_PLAYING' }
  | { type: 'DWELL_ELAPSED' }
  | { type: 'VISIBILITY_HIDDEN' }
  | { type: 'VISIBILITY_VISIBLE' }

export const STACK_MAX_DEPTH = 10
export const DWELL_MS = 20_000
```

- [ ] **Step 2: Verify the file compiles**

Run: `pnpm exec tsc --noEmit -p tsconfig.web.json` (in `apps/rishi-electron`)
Expected: PASS (or no new errors related to this file).

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/types.ts
git commit -m "feat(electron): navigation history type definitions"
```

---

### Task 2: pageKey helper

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/pageKey.ts`
- Test: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/pageKey.test.ts`

The `pageKey()` function normalizes a `PositionDescriptor` to a string key that ignores sub-page offset. For EPUB-family formats it extracts the spine index from the CFI by casting through `epubjs.EpubCFI` (the codebase already does this in `cfi-to-paragraph.ts:31`).

- [ ] **Step 1: Write the failing test**

```typescript
// apps/rishi-electron/src/renderer/src/machines/navigationHistory/pageKey.test.ts
import { describe, it, expect } from 'vitest'
import { pageKey } from './pageKey'

describe('pageKey', () => {
  it('PDF key ignores scroll offset', () => {
    expect(pageKey({ kind: 'pdf', page: 42, offset: 0 })).toBe('pdf:42')
    expect(pageKey({ kind: 'pdf', page: 42, offset: 350 })).toBe('pdf:42')
  })

  it('EPUB key reflects spine index only', () => {
    // CFI format: epubcfi(/6/<spinePos*2+2>!/...)
    const cfiA = 'epubcfi(/6/14!/4/2/2,/1:0,/1:100)'  // spinePos 6
    const cfiB = 'epubcfi(/6/14!/4/4/2,/1:0,/1:100)'  // same spinePos 6, different intra-spine
    expect(pageKey({ kind: 'epub', cfi: cfiA })).toBe(pageKey({ kind: 'epub', cfi: cfiB }))
  })

  it('different spine indices yield different keys', () => {
    const cfi1 = 'epubcfi(/6/4!/4/2/2,/1:0,/1:100)'   // spinePos 1
    const cfi2 = 'epubcfi(/6/14!/4/2/2,/1:0,/1:100)'  // spinePos 6
    expect(pageKey({ kind: 'epub', cfi: cfi1 })).not.toBe(pageKey({ kind: 'epub', cfi: cfi2 }))
  })

  it('AZW3 and MOBI share the epub keyspace', () => {
    const cfi = 'epubcfi(/6/14!/4/2/2,/1:0,/1:100)'
    expect(pageKey({ kind: 'azw3', cfi })).toBe(pageKey({ kind: 'epub', cfi }))
    expect(pageKey({ kind: 'mobi', cfi })).toBe(pageKey({ kind: 'epub', cfi }))
  })
})
```

- [ ] **Step 2: Run test to confirm failure**

Run: `pnpm test src/renderer/src/machines/navigationHistory/pageKey.test.ts`
Expected: FAIL — `Cannot find module './pageKey'`.

- [ ] **Step 3: Write the implementation**

```typescript
// apps/rishi-electron/src/renderer/src/machines/navigationHistory/pageKey.ts
import { EpubCFI } from 'epubjs'
import type { PositionDescriptor } from './types'

export function pageKey(position: PositionDescriptor): string {
  if (position.kind === 'pdf') {
    return `pdf:${position.page}`
  }
  const parsed = new EpubCFI(position.cfi)
  const spinePos = (parsed as unknown as { spinePos: number }).spinePos
  return `epub:${spinePos}`
}
```

- [ ] **Step 4: Run tests, confirm green**

Run: `pnpm test src/renderer/src/machines/navigationHistory/pageKey.test.ts`
Expected: PASS — 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/pageKey.ts apps/rishi-electron/src/renderer/src/machines/navigationHistory/pageKey.test.ts
git commit -m "feat(electron): pageKey normalizes positions for resume lookup"
```

---

## Phase 2 — `navigationHistoryMachine` (incrementally TDD'd)

The machine is built region-by-region. Each task adds one slice of behavior with its tests.

### Task 3: Machine skeleton — inactive ↔ active lifecycle

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts`
- Test: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createActor } from 'xstate'
import { navigationHistoryMachine } from './navigationHistoryMachine'
import type { PositionDescriptor } from './types'

const initialPdfPosition: PositionDescriptor = { kind: 'pdf', page: 1, offset: 0 }

function startActor() {
  const actor = createActor(navigationHistoryMachine)
  actor.start()
  return actor
}

describe('navigationHistoryMachine — lifecycle', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('starts in inactive', () => {
    const actor = startActor()
    expect(actor.getSnapshot().value).toBe('inactive')
    expect(actor.getSnapshot().context.bookId).toBeNull()
  })

  it('BOOK_OPENED transitions to active and stores bookId + currentPage', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'book-42', initialPosition: initialPdfPosition })
    const snap = actor.getSnapshot()
    expect(typeof snap.value).toBe('object') // parallel state
    expect(snap.context.bookId).toBe('book-42')
    expect(snap.context.currentPage).toEqual(initialPdfPosition)
  })

  it('BOOK_CLOSED clears stack, resumeMap, currentPage and returns to inactive', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'book-42', initialPosition: initialPdfPosition })
    actor.send({ type: 'BOOK_CLOSED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('inactive')
    expect(snap.context.bookId).toBeNull()
    expect(snap.context.stack).toEqual([])
    expect(snap.context.resumeMap.size).toBe(0)
    expect(snap.context.currentPage).toBeNull()
  })
})
```

- [ ] **Step 2: Run, confirm failure**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: FAIL — `Cannot find module './navigationHistoryMachine'`.

- [ ] **Step 3: Implement the skeleton**

```typescript
// apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts
import { setup, assign } from 'xstate'
import type { NavigationHistoryContext, NavigationHistoryEvent } from './types'

const initialContext = (): NavigationHistoryContext => ({
  bookId: null,
  stack: [],
  resumeMap: new Map(),
  currentPage: null,
  pillVisible: false
})

export const navigationHistoryMachine = setup({
  types: {
    context: {} as NavigationHistoryContext,
    events: {} as NavigationHistoryEvent
  },
  actions: {
    hydrateOnOpen: assign(({ event }) => {
      if (event.type !== 'BOOK_OPENED') return {}
      return {
        bookId: event.bookId,
        currentPage: event.initialPosition,
        stack: [],
        resumeMap: new Map(),
        pillVisible: false
      }
    }),
    clearAll: assign(() => initialContext())
  }
}).createMachine({
  id: 'navigationHistory',
  initial: 'inactive',
  context: initialContext(),
  states: {
    inactive: {
      on: {
        BOOK_OPENED: { target: 'active', actions: 'hydrateOnOpen' }
      }
    },
    active: {
      on: {
        BOOK_CLOSED: { target: 'inactive', actions: 'clearAll' }
      },
      type: 'parallel',
      states: {
        // stack, engagement, pill regions added in following tasks
        stack: { initial: 'idle', states: { idle: {} } },
        engagement: { initial: 'idle', states: { idle: {} } },
        pill: { initial: 'hidden', states: { hidden: {} } }
      }
    }
  }
})
```

- [ ] **Step 4: Run tests**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: PASS — 3 tests passing.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts
git commit -m "feat(electron): navigationHistoryMachine skeleton with lifecycle"
```

---

### Task 4: Stack region — JUMP_REQUESTED push, POP_BACK pop, depth cap

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts`
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`

- [ ] **Step 1: Add the failing tests**

Append to the existing test file:

```typescript
import { STACK_MAX_DEPTH } from './types'

describe('navigationHistoryMachine — stack', () => {
  const pos = (page: number): PositionDescriptor => ({ kind: 'pdf', page, offset: 0 })

  it('JUMP_REQUESTED pushes the from-anchor and enters stack.navigating', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(10),
      fromTts: null,
      to: pos(50),
      source: 'link',
      fromLabel: 'p. 10'
    })
    const snap = actor.getSnapshot()
    expect(snap.context.stack).toHaveLength(1)
    expect(snap.context.stack[0].position).toEqual(pos(10))
    expect(snap.context.stack[0].label).toBe('p. 10')
    expect(snap.context.stack[0].source).toBe('link')
    expect((snap.value as { stack: string }).stack).toBe('navigating')
  })

  it('stack.navigating returns to idle on PAGE_VISITED', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(10), fromTts: null, to: pos(50), source: 'link', fromLabel: 'p. 10'
    })
    actor.send({ type: 'PAGE_VISITED', position: pos(50), ttsContext: null })
    expect((actor.getSnapshot().value as { stack: string }).stack).toBe('idle')
  })

  it('POP_BACK removes top anchor and enters stack.navigating', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(10), fromTts: null, to: pos(50), source: 'link', fromLabel: 'p. 10'
    })
    actor.send({ type: 'PAGE_VISITED', position: pos(50), ttsContext: null })
    actor.send({ type: 'POP_BACK' })
    const snap = actor.getSnapshot()
    expect(snap.context.stack).toHaveLength(0)
    expect((snap.value as { stack: string }).stack).toBe('navigating')
  })

  it('POP_BACK on empty stack is a no-op', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({ type: 'POP_BACK' })
    expect(actor.getSnapshot().context.stack).toEqual([])
    expect((actor.getSnapshot().value as { stack: string }).stack).toBe('idle')
  })

  it('stack caps at STACK_MAX_DEPTH, dropping oldest', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(0) })
    for (let i = 0; i < STACK_MAX_DEPTH + 5; i++) {
      actor.send({
        type: 'JUMP_REQUESTED',
        from: pos(i),
        fromTts: null,
        to: pos(i + 100),
        source: 'link',
        fromLabel: `p. ${i}`
      })
      actor.send({ type: 'PAGE_VISITED', position: pos(i + 100), ttsContext: null })
    }
    const snap = actor.getSnapshot()
    expect(snap.context.stack).toHaveLength(STACK_MAX_DEPTH)
    // oldest entries dropped; first remaining should be from i=5
    expect(snap.context.stack[0].label).toBe('p. 5')
    expect(snap.context.stack[STACK_MAX_DEPTH - 1].label).toBe(`p. ${STACK_MAX_DEPTH + 4}`)
  })
})
```

- [ ] **Step 2: Run, confirm failure**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: FAIL — multiple errors (JUMP_REQUESTED not handled, etc.).

- [ ] **Step 3: Implement the stack region**

Replace the `stack` sub-state and add actions to the machine:

```typescript
// Replace the `actions` block in setup() with:
actions: {
  hydrateOnOpen: assign(({ event }) => {
    if (event.type !== 'BOOK_OPENED') return {}
    return {
      bookId: event.bookId,
      currentPage: event.initialPosition,
      stack: [],
      resumeMap: new Map(),
      pillVisible: false
    }
  }),
  clearAll: assign(() => initialContext()),
  pushAnchor: assign(({ context, event }) => {
    if (event.type !== 'JUMP_REQUESTED') return {}
    if (!context.bookId) return {}
    const anchor: AnchorPoint = {
      id: crypto.randomUUID(),
      bookId: context.bookId,
      position: event.from,
      tts: event.fromTts,
      label: event.fromLabel,
      capturedAt: Date.now(),
      source: event.source
    }
    const next = [...context.stack, anchor]
    if (next.length > STACK_MAX_DEPTH) next.splice(0, next.length - STACK_MAX_DEPTH)
    return { stack: next }
  }),
  popAnchor: assign(({ context }) => {
    if (context.stack.length === 0) return {}
    return { stack: context.stack.slice(0, -1) }
  })
},
guards: {
  hasStackEntries: ({ context }) => context.stack.length > 0
}
```

Add `AnchorPoint` and `STACK_MAX_DEPTH` imports at the top:

```typescript
import type { AnchorPoint, NavigationHistoryContext, NavigationHistoryEvent } from './types'
import { STACK_MAX_DEPTH } from './types'
```

Replace the `stack` sub-state:

```typescript
stack: {
  initial: 'idle',
  states: {
    idle: {
      on: {
        JUMP_REQUESTED: { target: 'navigating', actions: 'pushAnchor' },
        POP_BACK: { target: 'navigating', guard: 'hasStackEntries', actions: 'popAnchor' }
      }
    },
    navigating: {
      on: {
        PAGE_VISITED: { target: 'idle' }
      }
    }
  }
}
```

- [ ] **Step 4: Run tests**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: PASS — all stack tests + earlier lifecycle tests passing.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/
git commit -m "feat(electron): navigation history stack region with depth cap"
```

---

### Task 5: Engagement region — tap, TTS, dwell timer with visibility pause

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts`
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`

- [ ] **Step 1: Append failing tests**

```typescript
import { DWELL_MS } from './types'

describe('navigationHistoryMachine — engagement', () => {
  const pos = (page: number): PositionDescriptor => ({ kind: 'pdf', page, offset: 0 })

  function getEngagement(actor: ReturnType<typeof startActor>): string {
    return (actor.getSnapshot().value as { engagement: string }).engagement
  }

  it('starts in engagement.idle after BOOK_OPENED', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    expect(getEngagement(actor)).toBe('idle')
  })

  it('PAGE_VISITED moves engagement to dwelling', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    expect(getEngagement(actor)).toBe('dwelling')
  })

  it('ENGAGEMENT_TAP from idle goes straight to engaged', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('ENGAGEMENT_TTS_PLAYING also reaches engaged', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'ENGAGEMENT_TTS_PLAYING' })
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('DWELL_ELAPSED after DWELL_MS reaches engaged', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    vi.advanceTimersByTime(DWELL_MS)
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('VISIBILITY_HIDDEN pauses the dwell timer; VISIBILITY_VISIBLE resumes', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    vi.advanceTimersByTime(DWELL_MS - 1000)
    actor.send({ type: 'VISIBILITY_HIDDEN' })
    vi.advanceTimersByTime(60_000) // hidden window, should NOT fire
    expect(getEngagement(actor)).toBe('dwelling')
    actor.send({ type: 'VISIBILITY_VISIBLE' })
    vi.advanceTimersByTime(1000)
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('PAGE_VISITED to a different page resets engaged back to dwelling on new page', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    expect(getEngagement(actor)).toBe('engaged')
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    expect(getEngagement(actor)).toBe('dwelling')
  })
})
```

- [ ] **Step 2: Run, confirm failures**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: engagement tests fail (region only has `idle`).

- [ ] **Step 3: Implement engagement region with delayed transition**

Replace the `engagement` sub-state in the machine:

```typescript
engagement: {
  initial: 'idle',
  states: {
    idle: {
      on: {
        PAGE_VISITED: { target: 'dwelling' },
        ENGAGEMENT_TAP: { target: 'engaged' },
        ENGAGEMENT_TTS_PLAYING: { target: 'engaged' }
      }
    },
    dwelling: {
      after: {
        DWELL_TIMER: { target: 'engaged' }
      },
      on: {
        PAGE_VISITED: { target: 'dwelling', reenter: true }, // resets timer
        ENGAGEMENT_TAP: { target: 'engaged' },
        ENGAGEMENT_TTS_PLAYING: { target: 'engaged' },
        DWELL_ELAPSED: { target: 'engaged' },
        VISIBILITY_HIDDEN: { target: 'paused' }
      }
    },
    paused: {
      on: {
        VISIBILITY_VISIBLE: { target: 'dwelling', reenter: true } // resets timer
      }
    },
    engaged: {
      on: {
        PAGE_VISITED: { target: 'idle' }
      }
    }
  }
}
```

Add the delay to the setup `delays`:

```typescript
delays: {
  DWELL_TIMER: DWELL_MS
}
```

(Import `DWELL_MS` from `./types`.)

> **Note on the visibility-pause test:** After `VISIBILITY_VISIBLE` we `reenter: true` `dwelling` — this resets the timer rather than tracking elapsed-before-hide. The test advances by 1s after returning, then `vi.advanceTimersByTime(60_000)` while hidden does nothing because we left `dwelling`. We resume in fresh `dwelling`, and the existing test only advances 1s — which is insufficient for the timer. **Update the test:** change `vi.advanceTimersByTime(1000)` to `vi.advanceTimersByTime(DWELL_MS)`.

Apply that test edit before re-running.

- [ ] **Step 4: Run tests**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: PASS — all engagement tests + earlier tests passing.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/
git commit -m "feat(electron): engagement region with dwell timer and visibility pause"
```

---

### Task 6: Engagement writes to resumeMap; pill region

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts`
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`

- [ ] **Step 1: Append failing tests**

```typescript
describe('navigationHistoryMachine — resume map + pill', () => {
  const pos = (page: number, offset = 0): PositionDescriptor => ({ kind: 'pdf', page, offset })

  it('entering engaged writes currentPage anchor into resumeMap[pageKey]', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(7, 250) })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 250), ttsContext: { paragraphIndex: 3 } })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    const snap = actor.getSnapshot()
    const anchor = snap.context.resumeMap.get('pdf:7')
    expect(anchor).toBeDefined()
    expect(anchor!.position).toEqual(pos(7, 250))
    expect(anchor!.tts).toEqual({ paragraphIndex: 3 })
    expect(anchor!.source).toBe('engagement')
  })

  it('JUMP_REQUESTED shows pill; engagement.engaged hides pill', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    expect(actor.getSnapshot().context.pillVisible).toBe(false)
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(1), fromTts: null, to: pos(5), source: 'link', fromLabel: 'p. 1'
    })
    expect(actor.getSnapshot().context.pillVisible).toBe(true)
    actor.send({ type: 'PAGE_VISITED', position: pos(5), ttsContext: null })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    expect(actor.getSnapshot().context.pillVisible).toBe(false)
    // stack entry retained
    expect(actor.getSnapshot().context.stack).toHaveLength(1)
  })

  it('DISMISS_PILL hides without popping', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(1), fromTts: null, to: pos(5), source: 'link', fromLabel: 'p. 1'
    })
    actor.send({ type: 'DISMISS_PILL' })
    expect(actor.getSnapshot().context.pillVisible).toBe(false)
    expect(actor.getSnapshot().context.stack).toHaveLength(1)
  })
})
```

- [ ] **Step 2: Run, confirm failures**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: FAIL — pillVisible never toggles; resumeMap stays empty.

- [ ] **Step 3: Implement**

Add three actions in the setup:

```typescript
captureResumeAnchor: assign(({ context }) => {
  if (!context.bookId || !context.currentPage) return {}
  const anchor: AnchorPoint = {
    id: crypto.randomUUID(),
    bookId: context.bookId,
    position: context.currentPage,
    tts: context.currentTts ?? null,
    label: '',
    capturedAt: Date.now(),
    source: 'engagement'
  }
  const next = new Map(context.resumeMap)
  next.set(pageKey(context.currentPage), anchor)
  return { resumeMap: next }
}),
showPill: assign({ pillVisible: true }),
hidePill: assign({ pillVisible: false })
```

Add `pageKey` import:

```typescript
import { pageKey } from './pageKey'
```

Extend `NavigationHistoryContext` in `types.ts` with `currentTts: TtsContext` (default `null`); update `initialContext()` and `hydrateOnOpen` accordingly; in the existing `PAGE_VISITED` handler in stack region, also update `currentTts` via a `recordPageVisit` action:

```typescript
recordPageVisit: assign(({ event }) => {
  if (event.type !== 'PAGE_VISITED') return {}
  return { currentPage: event.position, currentTts: event.ttsContext }
}),
```

Wire `recordPageVisit` into all three regions' `PAGE_VISITED` handlers. The clean way: add a top-level `on: { PAGE_VISITED: { actions: 'recordPageVisit' } }` inside `active` (before the parallel block). XState v5 processes top-level transitions first, so context updates land before region transitions react.

Add `entry: 'captureResumeAnchor'` and `entry: 'hidePill'` to the `engagement.engaged` state. Replace its definition:

```typescript
engaged: {
  entry: ['captureResumeAnchor', 'hidePill'],
  on: {
    PAGE_VISITED: { target: 'idle' }
  }
}
```

Replace `pill` sub-state:

```typescript
pill: {
  initial: 'hidden',
  states: {
    hidden: {
      on: {
        JUMP_REQUESTED: { target: 'visible', actions: 'showPill' }
      }
    },
    visible: {
      on: {
        DISMISS_PILL: { target: 'hidden', actions: 'hidePill' }
        // hidePill is also fired on engagement.engaged entry above
        // POP_BACK transitions handled implicitly: when stack empties, hidePill
      }
    }
  }
}
```

Add a guard for empty-after-pop and have `POP_BACK` in `stack.idle` also fire `hidePill` when the stack becomes empty after the pop:

```typescript
// In stack.idle:
POP_BACK: {
  target: 'navigating',
  guard: 'hasStackEntries',
  actions: ['popAnchor', 'hidePillIfStackEmpty']
}
```

Add the action:

```typescript
hidePillIfStackEmpty: assign(({ context }) => {
  // popAnchor ran before this; context.stack already reflects the pop
  return context.stack.length === 0 ? { pillVisible: false } : {}
})
```

> **Order note:** XState v5 runs `assign` actions in the order listed, so `popAnchor` mutates first, then `hidePillIfStackEmpty` reads the post-pop stack.

- [ ] **Step 4: Run tests**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: PASS — all tests including the new resume-map and pill tests.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/
git commit -m "feat(electron): resume map capture on engagement + pill visibility transitions"
```

---

### Task 7: Smart resume on PAGE_VISITED (deliberate-jump-wins gate)

The resume restoration is emitted as a side-effect event the React layer consumes. The machine doesn't navigate the reader directly — it surfaces an intent. We expose this via an `emit` action so subscribers can listen for `'RESUME_REQUESTED'` events with the target anchor.

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.ts`
- Modify: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`

- [ ] **Step 1: Append failing tests**

```typescript
import type { AnchorPoint } from './types'

describe('navigationHistoryMachine — smart resume', () => {
  const pos = (page: number, offset = 0): PositionDescriptor => ({ kind: 'pdf', page, offset })

  function captureEmitted(actor: ReturnType<typeof startActor>): AnchorPoint[] {
    const out: AnchorPoint[] = []
    actor.on('RESUME_REQUESTED' as never, (e: { anchor: AnchorPoint }) => {
      out.push(e.anchor)
    })
    return out
  }

  it('PAGE_VISITED to a page with stored anchor emits RESUME_REQUESTED', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(7, 250) })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 250), ttsContext: { paragraphIndex: 3 } })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    // navigate away
    actor.send({ type: 'PAGE_VISITED', position: pos(9), ttsContext: null })

    const emitted = captureEmitted(actor)
    // return to page 7 via plain page-flip
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 0), ttsContext: null })
    expect(emitted).toHaveLength(1)
    expect(emitted[0].position).toEqual(pos(7, 250))
  })

  it('PAGE_VISITED that arrives during stack.navigating does NOT emit (deliberate jump wins)', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(7, 250) })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 250), ttsContext: { paragraphIndex: 3 } })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    actor.send({ type: 'PAGE_VISITED', position: pos(9), ttsContext: null })

    const emitted = captureEmitted(actor)
    // jump back to page 7 deliberately
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(9), fromTts: null, to: pos(7, 100), source: 'link', fromLabel: 'p. 9'
    })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 100), ttsContext: null })
    expect(emitted).toHaveLength(0) // deliberate jump wins
  })

  it('PAGE_VISITED to a page with no stored anchor does not emit', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    const emitted = captureEmitted(actor)
    actor.send({ type: 'PAGE_VISITED', position: pos(50), ttsContext: null })
    expect(emitted).toHaveLength(0)
  })
})
```

- [ ] **Step 2: Run, confirm failures**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: FAIL — `actor.on('RESUME_REQUESTED', ...)` listener never fires.

- [ ] **Step 3: Implement**

Add an emitted event type to `types.ts`:

```typescript
export type NavigationHistoryEmitted = { type: 'RESUME_REQUESTED'; anchor: AnchorPoint }
```

In the machine setup:

```typescript
types: {
  context: {} as NavigationHistoryContext,
  events: {} as NavigationHistoryEvent,
  emitted: {} as NavigationHistoryEmitted
}
```

Add the action — note we need to emit *before* the stack region transitions out of `navigating`, but only when stack is in `idle`. The simplest way: handle PAGE_VISITED at the `active` level with a guard:

```typescript
// Inside active state, alongside the parallel block:
on: {
  PAGE_VISITED: {
    actions: ['recordPageVisit', 'maybeEmitResume']
  },
  // BOOK_CLOSED already here
  BOOK_CLOSED: { target: '.inactive' }   // adjust path syntax
}
```

(Actually the `BOOK_CLOSED` lives on `active` already; just ensure both stay.)

The `maybeEmitResume` action checks the current `stack` region state via the state-value snapshot. Since we can't read sibling region state from inside `assign`, we use a `raise`-style pattern: track stack-busy in context.

Add `stackNavigating: boolean` to `NavigationHistoryContext` (default `false`). In stack region:
- `idle` `entry: 'markStackIdle'`
- `navigating` `entry: 'markStackBusy'`

```typescript
markStackIdle: assign({ stackNavigating: false }),
markStackBusy: assign({ stackNavigating: true })
```

Then:

```typescript
maybeEmitResume: ({ context, event }, _params, { self }) => {
  if (event.type !== 'PAGE_VISITED') return
  if (context.stackNavigating) return // deliberate jump in flight
  const anchor = context.resumeMap.get(pageKey(event.position))
  if (!anchor) return
  self.send({ type: '__NOOP__' } as never) // placeholder if needed
  // Actual emit: use the machine's `emit` API
}
```

XState v5 emit syntax:

```typescript
import { emit } from 'xstate'

// In setup actions:
maybeEmitResume: emit(({ context, event }) => {
  if (event.type !== 'PAGE_VISITED') return undefined as never
  if (context.stackNavigating) return undefined as never
  const anchor = context.resumeMap.get(pageKey(event.position))
  if (!anchor) return undefined as never
  return { type: 'RESUME_REQUESTED', anchor }
})
```

> **Important:** `emit` only fires when the function returns a non-undefined event. The above signature satisfies XState v5; if the type checker complains about `undefined`, wrap with a conditional emit (call `emit({...})` directly from a regular action via a `params` factory). The actor-level listener `actor.on('RESUME_REQUESTED', ...)` consumes these events.

**Critical ordering:** the top-level `PAGE_VISITED` handler's `actions` array runs `recordPageVisit` (assign) then `maybeEmitResume` (emit) — and THEN the parallel regions' own `PAGE_VISITED` handlers fire, transitioning stack from `navigating` → `idle`. So `context.stackNavigating` is still `true` at the moment of emission for an in-flight jump. Good.

- [ ] **Step 4: Run tests**

Run: `pnpm test src/renderer/src/machines/navigationHistory/navigationHistoryMachine.test.ts`
Expected: PASS — all resume tests + prior tests passing.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/
git commit -m "feat(electron): emit RESUME_REQUESTED on returning to engaged page"
```

---

## Phase 3 — React layer

### Task 8: Add `@xstate/react` dependency

**Files:**
- Modify: `apps/rishi-electron/package.json`

- [ ] **Step 1: Install**

Run from repo root:
```bash
pnpm --filter rishi-electron add @xstate/react@^5
```

- [ ] **Step 2: Verify lockfile updated**

Run: `git status apps/rishi-electron/package.json pnpm-lock.yaml`
Expected: both files modified.

- [ ] **Step 3: Smoke-test that the import resolves**

Create a throwaway: `pnpm exec tsc --noEmit -p apps/rishi-electron/tsconfig.web.json`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/package.json pnpm-lock.yaml
git commit -m "build(electron): add @xstate/react for navigation history"
```

---

### Task 9: Singleton actor + send-only Zustand wrapper

The actor is module-scoped so iframe handlers and class components can dispatch events without prop-drilling. The send-only wrapper mirrors the existing `navStore.ts` pattern.

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryActor.ts`

- [ ] **Step 1: Write the file**

```typescript
// apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryActor.ts
import { createActor } from 'xstate'
import { create } from 'zustand'
import { navigationHistoryMachine } from './navigationHistoryMachine'
import type { NavigationHistoryEvent } from './types'

export const navigationHistoryActor = createActor(navigationHistoryMachine)
navigationHistoryActor.start()

type SendStore = {
  send: (event: NavigationHistoryEvent) => void
}

export const useNavigationHistorySend = create<SendStore>(() => ({
  send: (event) => navigationHistoryActor.send(event)
}))

// Convenience: subscribe to RESUME_REQUESTED at module level (consumers can also listen via actor.on)
export function onResumeRequested(handler: (anchor: import('./types').AnchorPoint) => void): () => void {
  const sub = navigationHistoryActor.on(
    'RESUME_REQUESTED' as never,
    (e: { type: string; anchor: import('./types').AnchorPoint }) => handler(e.anchor)
  )
  return () => sub.unsubscribe()
}
```

- [ ] **Step 2: Verify it compiles**

Run: `pnpm exec tsc --noEmit -p apps/rishi-electron/tsconfig.web.json`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/navigationHistory/navigationHistoryActor.ts
git commit -m "feat(electron): navigation history singleton actor + send-only store"
```

---

### Task 10: `useNavigationHistory` selectors hook

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/hooks/useNavigationHistory.ts`

- [ ] **Step 1: Write the hook**

```typescript
// apps/rishi-electron/src/renderer/src/hooks/useNavigationHistory.ts
import { useSelector } from '@xstate/react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'
import type { AnchorPoint } from '@/machines/navigationHistory/types'

export function usePillVisible(): boolean {
  return useSelector(navigationHistoryActor, (s) => s.context.pillVisible)
}

export function useTopAnchor(): AnchorPoint | null {
  return useSelector(navigationHistoryActor, (s) => {
    const stack = s.context.stack
    return stack.length === 0 ? null : stack[stack.length - 1]
  })
}

export function useStackDepth(): number {
  return useSelector(navigationHistoryActor, (s) => s.context.stack.length)
}
```

- [ ] **Step 2: Compile**

Run: `pnpm exec tsc --noEmit -p apps/rishi-electron/tsconfig.web.json`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/hooks/useNavigationHistory.ts
git commit -m "feat(electron): React selector hooks for navigation history"
```

---

### Task 11: `useEngagementDetector` hook

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/hooks/useEngagementDetector.ts`
- Test: `apps/rishi-electron/src/renderer/src/hooks/useEngagementDetector.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
// apps/rishi-electron/src/renderer/src/hooks/useEngagementDetector.test.tsx
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useEngagementDetector } from './useEngagementDetector'

const sendMock = vi.fn()
vi.mock('@/machines/navigationHistory/navigationHistoryActor', () => ({
  navigationHistoryActor: { send: (e: unknown) => sendMock(e) }
}))

describe('useEngagementDetector', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    sendMock.mockClear()
  })
  afterEach(() => vi.useRealTimers())

  it('fires ENGAGEMENT_TAP on pointerdown', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    act(() => {
      targetRef.current.dispatchEvent(new PointerEvent('pointerdown'))
    })
    expect(sendMock).toHaveBeenCalledWith({ type: 'ENGAGEMENT_TAP' })
  })

  it('fires ENGAGEMENT_TAP on selectionchange when a non-collapsed range exists', () => {
    const targetRef = { current: document.createElement('div') }
    document.body.appendChild(targetRef.current)
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    // simulate a real selection
    const range = document.createRange()
    range.selectNodeContents(targetRef.current)
    window.getSelection()?.removeAllRanges()
    window.getSelection()?.addRange(range)
    act(() => {
      document.dispatchEvent(new Event('selectionchange'))
    })
    expect(sendMock).toHaveBeenCalledWith({ type: 'ENGAGEMENT_TAP' })
  })

  it('does NOT fire when enabled is false', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: false }))
    act(() => {
      targetRef.current.dispatchEvent(new PointerEvent('pointerdown'))
    })
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('fires VISIBILITY_HIDDEN on visibilitychange when document hidden', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    act(() => {
      document.dispatchEvent(new Event('visibilitychange'))
    })
    expect(sendMock).toHaveBeenCalledWith({ type: 'VISIBILITY_HIDDEN' })
  })
})
```

- [ ] **Step 2: Run, confirm failure**

Run: `pnpm test src/renderer/src/hooks/useEngagementDetector.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the hook**

```typescript
// apps/rishi-electron/src/renderer/src/hooks/useEngagementDetector.ts
import { useEffect, type RefObject } from 'react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'

export type UseEngagementDetectorOptions = {
  targetRef: RefObject<HTMLElement | null>
  enabled: boolean
}

export function useEngagementDetector({ targetRef, enabled }: UseEngagementDetectorOptions): void {
  useEffect(() => {
    if (!enabled) return
    const node = targetRef.current
    if (!node) return

    const onPointerDown = (): void => navigationHistoryActor.send({ type: 'ENGAGEMENT_TAP' })

    const onSelectionChange = (): void => {
      const sel = window.getSelection()
      if (!sel || sel.isCollapsed) return
      navigationHistoryActor.send({ type: 'ENGAGEMENT_TAP' })
    }

    const onVisibility = (): void => {
      navigationHistoryActor.send({
        type: document.visibilityState === 'hidden' ? 'VISIBILITY_HIDDEN' : 'VISIBILITY_VISIBLE'
      })
    }

    const onBlur = (): void => navigationHistoryActor.send({ type: 'VISIBILITY_HIDDEN' })
    const onFocus = (): void => navigationHistoryActor.send({ type: 'VISIBILITY_VISIBLE' })

    node.addEventListener('pointerdown', onPointerDown)
    document.addEventListener('selectionchange', onSelectionChange)
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', onBlur)
    window.addEventListener('focus', onFocus)

    return () => {
      node.removeEventListener('pointerdown', onPointerDown)
      document.removeEventListener('selectionchange', onSelectionChange)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('blur', onBlur)
      window.removeEventListener('focus', onFocus)
    }
  }, [targetRef, enabled])
}
```

- [ ] **Step 4: Run tests, confirm green**

Run: `pnpm test src/renderer/src/hooks/useEngagementDetector.test.tsx`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/hooks/useEngagementDetector.ts apps/rishi-electron/src/renderer/src/hooks/useEngagementDetector.test.tsx
git commit -m "feat(electron): useEngagementDetector hook for engagement signals"
```

---

### Task 12: `<NavigationHistoryFooter />` component

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/navigation-history/NavigationHistoryFooter.tsx`
- Test: `apps/rishi-electron/src/renderer/src/components/navigation-history/NavigationHistoryFooter.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
// apps/rishi-electron/src/renderer/src/components/navigation-history/NavigationHistoryFooter.test.tsx
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, fireEvent } from '@testing-library/react'

const sendMock = vi.fn()
let pillVisible = false
let topAnchor: { label: string } | null = null
let stackDepth = 0

vi.mock('@/hooks/useNavigationHistory', () => ({
  usePillVisible: () => pillVisible,
  useTopAnchor: () => topAnchor,
  useStackDepth: () => stackDepth
}))

vi.mock('@/machines/navigationHistory/navigationHistoryActor', () => ({
  navigationHistoryActor: { send: (e: unknown) => sendMock(e) }
}))

import { NavigationHistoryFooter } from './NavigationHistoryFooter'

describe('NavigationHistoryFooter', () => {
  beforeEach(() => {
    sendMock.mockClear()
    pillVisible = false
    topAnchor = null
    stackDepth = 0
  })

  it('renders nothing when pill is hidden', () => {
    const { container } = render(<NavigationHistoryFooter />)
    expect(container.firstChild).toBeNull()
  })

  it('renders label when visible', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 1
    const { getByRole } = render(<NavigationHistoryFooter />)
    expect(getByRole('status')).toHaveTextContent('p. 142')
  })

  it('appends stack depth when >1', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 3
    const { getByRole } = render(<NavigationHistoryFooter />)
    expect(getByRole('status')).toHaveTextContent('p. 142 (3)')
  })

  it('label click dispatches POP_BACK', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 1
    const { getByTestId } = render(<NavigationHistoryFooter />)
    fireEvent.click(getByTestId('nav-history-back-label'))
    expect(sendMock).toHaveBeenCalledWith({ type: 'POP_BACK' })
  })

  it('dismiss button dispatches DISMISS_PILL', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 1
    const { getByTestId } = render(<NavigationHistoryFooter />)
    fireEvent.click(getByTestId('nav-history-dismiss'))
    expect(sendMock).toHaveBeenCalledWith({ type: 'DISMISS_PILL' })
  })
})
```

- [ ] **Step 2: Run, confirm failure**

Run: `pnpm test src/renderer/src/components/navigation-history/NavigationHistoryFooter.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the component**

```tsx
// apps/rishi-electron/src/renderer/src/components/navigation-history/NavigationHistoryFooter.tsx
import { type JSX } from 'react'
import { usePillVisible, useTopAnchor, useStackDepth } from '@/hooks/useNavigationHistory'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'

export function NavigationHistoryFooter(): JSX.Element | null {
  const visible = usePillVisible()
  const anchor = useTopAnchor()
  const depth = useStackDepth()

  if (!visible || !anchor) return null

  const text = depth > 1 ? `← Back to ${anchor.label} (${depth})` : `← Back to ${anchor.label}`

  return (
    <div
      role="status"
      aria-live="polite"
      className="pointer-events-auto fixed bottom-16 left-1/2 z-50 -translate-x-1/2
                 flex items-center gap-2 rounded-full border border-white/10
                 bg-zinc-900/95 px-4 py-2 text-sm text-white shadow-lg backdrop-blur"
    >
      <button
        type="button"
        data-testid="nav-history-back-label"
        onClick={() => navigationHistoryActor.send({ type: 'POP_BACK' })}
        className="min-h-[44px] px-2"
      >
        {text}
      </button>
      <button
        type="button"
        data-testid="nav-history-dismiss"
        aria-label="Dismiss back navigation"
        onClick={() => navigationHistoryActor.send({ type: 'DISMISS_PILL' })}
        className="min-h-[44px] px-2 opacity-60 hover:opacity-100"
      >
        ✕
      </button>
    </div>
  )
}
```

- [ ] **Step 4: Run tests**

Run: `pnpm test src/renderer/src/components/navigation-history/NavigationHistoryFooter.test.tsx`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/navigation-history/
git commit -m "feat(electron): NavigationHistoryFooter pill component"
```

---

### Task 13: Global keyboard shortcut `Cmd/Ctrl+[` → POP_BACK

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/hooks/useNavigationHistoryKeyboard.ts`
- Test: `apps/rishi-electron/src/renderer/src/hooks/useNavigationHistoryKeyboard.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
// apps/rishi-electron/src/renderer/src/hooks/useNavigationHistoryKeyboard.test.tsx
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'

const sendMock = vi.fn()
vi.mock('@/machines/navigationHistory/navigationHistoryActor', () => ({
  navigationHistoryActor: { send: (e: unknown) => sendMock(e) }
}))

import { useNavigationHistoryKeyboard } from './useNavigationHistoryKeyboard'

describe('useNavigationHistoryKeyboard', () => {
  beforeEach(() => sendMock.mockClear())

  it('Cmd+[ dispatches POP_BACK', () => {
    renderHook(() => useNavigationHistoryKeyboard())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '[', metaKey: true }))
    expect(sendMock).toHaveBeenCalledWith({ type: 'POP_BACK' })
  })

  it('Ctrl+[ dispatches POP_BACK', () => {
    renderHook(() => useNavigationHistoryKeyboard())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '[', ctrlKey: true }))
    expect(sendMock).toHaveBeenCalledWith({ type: 'POP_BACK' })
  })

  it('plain [ does NOT dispatch', () => {
    renderHook(() => useNavigationHistoryKeyboard())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '[' }))
    expect(sendMock).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run, confirm failure**

Run: `pnpm test src/renderer/src/hooks/useNavigationHistoryKeyboard.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the hook**

```typescript
// apps/rishi-electron/src/renderer/src/hooks/useNavigationHistoryKeyboard.ts
import { useEffect } from 'react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'

export function useNavigationHistoryKeyboard(): void {
  useEffect(() => {
    const handler = (e: KeyboardEvent): void => {
      if (e.key !== '[') return
      if (!(e.metaKey || e.ctrlKey)) return
      e.preventDefault()
      navigationHistoryActor.send({ type: 'POP_BACK' })
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [])
}
```

- [ ] **Step 4: Run tests**

Run: `pnpm test src/renderer/src/hooks/useNavigationHistoryKeyboard.test.tsx`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/hooks/useNavigationHistoryKeyboard.ts apps/rishi-electron/src/renderer/src/hooks/useNavigationHistoryKeyboard.test.tsx
git commit -m "feat(electron): Cmd/Ctrl+[ keyboard shortcut for back navigation"
```

---

## Phase 4 — Per-format integration

These tasks wire the existing readers to dispatch lifecycle and jump events. Each format gets one task. Integration tests for these live alongside the per-format reader; we add focused unit tests around the new logic but rely on Phase 5 E2E for full coverage.

### Task 14: PDF integration

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.tsx`

Three integration points:
1. Lifecycle: `BOOK_OPENED` on mount, `BOOK_CLOSED` on unmount
2. `PAGE_VISITED` on every page change (already tracked via `pdfReaderMachine`)
3. `JUMP_REQUESTED` from TOC clicks (`onItemClick` at `pdf.tsx:374-380`) and from PDF annotation link clicks (in `pdf-page.tsx`)
4. Mount `<NavigationHistoryFooter />`
5. Install `useEngagementDetector` and `useNavigationHistoryKeyboard`

- [ ] **Step 1: Add lifecycle + footer mount + engagement detector to `pdf.tsx`**

Inside the `PdfView` component (or whichever top-level PDF component lives in `pdf.tsx`), add near the existing effects:

```typescript
import { useEffect, useRef } from 'react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'
import { useEngagementDetector } from '@/hooks/useEngagementDetector'
import { useNavigationHistoryKeyboard } from '@/hooks/useNavigationHistoryKeyboard'
import { NavigationHistoryFooter } from '@/components/navigation-history/NavigationHistoryFooter'

// inside component:
const readerRootRef = useRef<HTMLDivElement>(null)

useEffect(() => {
  navigationHistoryActor.send({
    type: 'BOOK_OPENED',
    bookId: String(book.id),
    initialPosition: { kind: 'pdf', page: pdfReader.currentPage, offset: pdfReader.currentOffset ?? 0 }
  })
  return () => navigationHistoryActor.send({ type: 'BOOK_CLOSED' })
}, [book.id])

useEngagementDetector({ targetRef: readerRootRef, enabled: true })
useNavigationHistoryKeyboard()

// On every page change (subscribe to pdfReader state):
useEffect(() => {
  navigationHistoryActor.send({
    type: 'PAGE_VISITED',
    position: { kind: 'pdf', page: pdfReader.currentPage, offset: pdfReader.currentOffset ?? 0 },
    ttsContext: playerStore.activeParagraph != null ? { paragraphIndex: playerStore.activeParagraph } : null
  })
}, [pdfReader.currentPage, pdfReader.currentOffset])
```

Wrap the existing return element so `readerRootRef` is set, and append `<NavigationHistoryFooter />`:

```tsx
return (
  <div ref={readerRootRef} className="relative h-full">
    {/* existing PDF reader JSX */}
    <NavigationHistoryFooter />
  </div>
)
```

- [ ] **Step 2: Wrap TOC `onItemClick` in `pdf.tsx:374-380`**

Replace:

```typescript
const onItemClick = useCallback(
  ({ pageNumber: itemPageNumber }: { pageNumber: number }) => {
    pdfReader.seekTo(itemPageNumber)
    setTocOpen(false)
  },
  [pdfReader]
)
```

with:

```typescript
const onItemClick = useCallback(
  ({ pageNumber: itemPageNumber }: { pageNumber: number }) => {
    const fromPosition = { kind: 'pdf' as const, page: pdfReader.currentPage, offset: pdfReader.currentOffset ?? 0 }
    const fromTts = playerStore.activeParagraph != null ? { paragraphIndex: playerStore.activeParagraph } : null
    navigationHistoryActor.send({
      type: 'JUMP_REQUESTED',
      from: fromPosition,
      fromTts,
      to: { kind: 'pdf', page: itemPageNumber, offset: 0 },
      source: 'toc',
      fromLabel: `p. ${pdfReader.currentPage}`
    })
    pdfReader.seekTo(itemPageNumber)
    setTocOpen(false)
  },
  [pdfReader]
)
```

- [ ] **Step 3: Intercept PDF annotation link clicks in `pdf-page.tsx`**

In the `<Page>` render block (~line 150-173), the AnnotationLayer renders anchors with class `react-pdf__Page__annotations`. Add an `onClick` capture on the wrapping element:

```typescript
function handleAnnotationClick(e: React.MouseEvent<HTMLDivElement>): void {
  const target = e.target as HTMLElement
  const link = target.closest('a[data-target-page]') as HTMLAnchorElement | null
  if (!link) return
  const targetPage = Number(link.dataset.targetPage)
  if (!Number.isFinite(targetPage)) return
  e.preventDefault()
  const fromPosition = { kind: 'pdf' as const, page: currentPage, offset: currentOffset }
  navigationHistoryActor.send({
    type: 'JUMP_REQUESTED',
    from: fromPosition,
    fromTts: null,
    to: { kind: 'pdf', page: targetPage, offset: 0 },
    source: 'link',
    fromLabel: `p. ${currentPage}`
  })
  pdfReader.seekTo(targetPage)
}

// wrap the <Page> in a div:
<div onClickCapture={handleAnnotationClick}>
  <Page {...existingProps} />
</div>
```

> **Note:** react-pdf's AnnotationLayer renders internal-link annotations as plain `<a href>` elements with `data-page-number` (varies by version). The selector above uses `data-target-page` as illustration — **inspect the rendered DOM** for the actual attribute (it may be `data-page-number` or simply an `href="#page=N"`). Adjust the selector accordingly. If linking is purely href-based:
> ```typescript
> const link = target.closest('a[href*="page="]') as HTMLAnchorElement | null
> const match = link?.getAttribute('href')?.match(/page=(\d+)/)
> const targetPage = match ? Number(match[1]) : NaN
> ```

- [ ] **Step 4: Subscribe to RESUME_REQUESTED in `pdf.tsx`**

Add an effect that wires the resume intent into `pdfReader.seekTo`:

```typescript
import { onResumeRequested } from '@/machines/navigationHistory/navigationHistoryActor'

useEffect(() => {
  return onResumeRequested((anchor) => {
    if (anchor.position.kind !== 'pdf') return
    pdfReader.seekTo(anchor.position.page, { offset: anchor.position.offset })
    if (anchor.tts) {
      // Hand the paragraph index to playerMachine via existing PARAGRAPHS_UPDATED flow.
      // For v1, leaving auto-resume to the existing playerMachine wantsAutoResume logic is sufficient.
    }
  })
}, [pdfReader])
```

> **Note:** the existing `pdfReader.seekTo` signature may not accept an `offset` parameter. If not, extend it: `seekTo(page: number, opts?: { offset?: number })` and route `opts.offset` to the existing `pendingOffset` mechanism in `usePdfReader.ts` (line 25-26 per exploration). This is a small targeted change; do not refactor surrounding code.

- [ ] **Step 5: Manual smoke test**

Run: `pnpm dev` (or whatever launches rishi-electron locally)
1. Open a PDF with a TOC
2. Click a TOC entry — pill appears at bottom with prior page label
3. Click pill — returns to prior page
4. Open a PDF with internal links; click one — pill appears; tap to return
5. Without engagement, page-flip forward a few pages and back — should resume from initial page

- [ ] **Step 6: Run all tests to confirm no regressions**

Run: `pnpm test`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/
git commit -m "feat(electron): wire PDF reader to navigation history (TOC + links + resume)"
```

---

### Task 15: EPUB integration

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/react-reader/epub_viewer/index.tsx`

- [ ] **Step 1: Wire body link interception in `epub_viewer/index.tsx`**

The rendition is created at line 242 of `react-reader/epub_viewer/index.tsx`. After the rendition is created and the `relocated`/`selected` handlers are registered (~line 287-290), add:

```typescript
// Intercept body link clicks
this.rendition.hooks.content.register((contents: { document: Document }) => {
  contents.document.addEventListener('click', (event: Event) => {
    const target = event.target as HTMLElement | null
    const anchor = target?.closest('a[href]') as HTMLAnchorElement | null
    if (!anchor) return
    const href = anchor.getAttribute('href')
    if (!href) return
    // Skip external links
    if (/^(https?:|mailto:)/i.test(href)) return
    event.preventDefault()
    // Resolve href against current spine item to a CFI
    const currentCfi = this.rendition.currentLocation()?.start?.cfi
    if (!currentCfi) return
    // emit jump via singleton actor
    import('@/machines/navigationHistory/navigationHistoryActor').then((m) => {
      const fromTts = null // class component has no playerStore access; pass null
      m.navigationHistoryActor.send({
        type: 'JUMP_REQUESTED',
        from: { kind: 'epub', cfi: currentCfi },
        fromTts,
        to: { kind: 'epub', cfi: href }, // epub.js resolves href via display()
        source: 'link',
        fromLabel: this.lookupChapterLabel(currentCfi) ?? 'previous spot'
      })
      this.rendition.display(href)
    })
  })
})
```

Add the `lookupChapterLabel` method to the same class:

```typescript
private lookupChapterLabel(cfi: string): string | null {
  try {
    const item = this.book?.navigation?.get?.(cfi)
    return item?.label?.trim() ?? null
  } catch {
    return null
  }
}
```

> **Note on `fromTts: null`:** the class component has no React context; getting the TTS paragraph here requires reading from the Zustand `playerStore` directly. Import at the top of the file: `import { usePlayerStore } from '@/stores/playerStore'`. Then: `const tts = usePlayerStore.getState().activeParagraph; const fromTts = tts != null ? { paragraphIndex: tts } : null`.

- [ ] **Step 2: Wrap `setLocation` callsite in `EpubView.tsx`**

Find the TOC/bookmark click handler that calls `setLocation(href)` (per exploration, this routes through `setLocation` which eventually calls `rendition.display`). Wrap each callsite with a `JUMP_REQUESTED`:

```typescript
const handleTocClick = useCallback((href: string, label: string) => {
  const currentCfi = currentEpubLocation
  if (currentCfi) {
    navigationHistoryActor.send({
      type: 'JUMP_REQUESTED',
      from: { kind: 'epub', cfi: currentCfi },
      fromTts: playerStore.activeParagraph != null ? { paragraphIndex: playerStore.activeParagraph } : null,
      to: { kind: 'epub', cfi: href },
      source: 'toc',
      fromLabel: label || 'previous spot'
    })
  }
  setLocation(href)
}, [currentEpubLocation, setLocation, playerStore.activeParagraph])
```

Repeat for bookmark- and search-result handlers (`source: 'bookmark'`, `'search'`).

- [ ] **Step 3: Add lifecycle + PAGE_VISITED + footer mount in `EpubView.tsx`**

Inside `EpubView`, near existing effects:

```typescript
import { navigationHistoryActor, onResumeRequested } from '@/machines/navigationHistory/navigationHistoryActor'
import { useEngagementDetector } from '@/hooks/useEngagementDetector'
import { useNavigationHistoryKeyboard } from '@/hooks/useNavigationHistoryKeyboard'
import { NavigationHistoryFooter } from '@/components/navigation-history/NavigationHistoryFooter'

const readerRootRef = useRef<HTMLDivElement>(null)

useEffect(() => {
  if (!currentEpubLocation) return
  navigationHistoryActor.send({
    type: 'BOOK_OPENED',
    bookId: String(book.id),
    initialPosition: { kind: 'epub', cfi: currentEpubLocation }
  })
  return () => navigationHistoryActor.send({ type: 'BOOK_CLOSED' })
}, [book.id])

// PAGE_VISITED on rendition relocate
useEffect(() => {
  if (!currentEpubLocation) return
  navigationHistoryActor.send({
    type: 'PAGE_VISITED',
    position: { kind: 'epub', cfi: currentEpubLocation },
    ttsContext: playerStore.activeParagraph != null ? { paragraphIndex: playerStore.activeParagraph } : null
  })
}, [currentEpubLocation])

// RESUME_REQUESTED → display the stored CFI
useEffect(() => {
  return onResumeRequested((anchor) => {
    if (anchor.position.kind !== 'epub') return
    rendition?.display(anchor.position.cfi)
  })
}, [rendition])

useEngagementDetector({ targetRef: readerRootRef, enabled: true })
useNavigationHistoryKeyboard()
```

Wrap the existing return:

```tsx
<div ref={readerRootRef} className="relative h-full">
  {/* existing EpubView JSX */}
  <NavigationHistoryFooter />
</div>
```

- [ ] **Step 4: Manual smoke test**

Run: `pnpm dev`
1. Open an EPUB with footnotes — click a footnote link → pill appears with chapter label → click pill → back
2. Click a TOC entry → pill → back
3. Page-flip without engagement → return resumes from initial CFI
4. Open chapter, tap to engage, flip forward a few pages, flip back → lands at the tapped CFI

- [ ] **Step 5: Run all tests, no regressions**

Run: `pnpm test`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/epub/ apps/rishi-electron/src/renderer/src/components/react-reader/
git commit -m "feat(electron): wire EPUB reader to navigation history"
```

---

### Task 16: AZW3 / MOBI integration

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx`

AZW3 and MOBI share `Azw3View.tsx` per the exploration. If it uses an epub.js-like rendition, replicate the EPUB integration pattern; if it uses a different renderer, hook into that renderer's link/click and location events instead.

- [ ] **Step 1: Inspect `Azw3View.tsx`**

Read: `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx`

Identify:
- Where the renderer is created and where link-click events are surfaced
- Where the current position (CFI or analog) is tracked
- Where TOC/bookmark navigation is invoked

- [ ] **Step 2: Add imports at top of `Azw3View.tsx`**

```typescript
import { useEffect, useRef } from 'react'
import {
  navigationHistoryActor,
  onResumeRequested
} from '@/machines/navigationHistory/navigationHistoryActor'
import { useEngagementDetector } from '@/hooks/useEngagementDetector'
import { useNavigationHistoryKeyboard } from '@/hooks/useNavigationHistoryKeyboard'
import { NavigationHistoryFooter } from '@/components/navigation-history/NavigationHistoryFooter'
import { usePlayerStore } from '@/stores/playerStore'
```

- [ ] **Step 3: Add lifecycle, PAGE_VISITED, resume subscription, engagement detector, keyboard**

Inside the `Azw3View` component (replace placeholders `<currentCfi expression>` and `<rendition handle>` with the actual local variable names you found in Step 1):

```typescript
const readerRootRef = useRef<HTMLDivElement>(null)
const activeParagraph = usePlayerStore((s) => s.activeParagraph)
const formatKind = book.kind === 'mobi' ? 'mobi' as const : 'azw3' as const

useEffect(() => {
  const cfi = /* <currentCfi expression> */ ''
  if (!cfi) return
  navigationHistoryActor.send({
    type: 'BOOK_OPENED',
    bookId: String(book.id),
    initialPosition: { kind: formatKind, cfi }
  })
  return () => navigationHistoryActor.send({ type: 'BOOK_CLOSED' })
}, [book.id])

useEffect(() => {
  const cfi = /* <currentCfi expression> */ ''
  if (!cfi) return
  navigationHistoryActor.send({
    type: 'PAGE_VISITED',
    position: { kind: formatKind, cfi },
    ttsContext: activeParagraph != null ? { paragraphIndex: activeParagraph } : null
  })
}, [/* <currentCfi dependency> */, activeParagraph])

useEffect(() => {
  return onResumeRequested((anchor) => {
    if (anchor.position.kind !== formatKind) return
    /* <rendition handle>.display(anchor.position.cfi) */
  })
}, [/* <rendition handle> */])

useEngagementDetector({ targetRef: readerRootRef, enabled: true })
useNavigationHistoryKeyboard()
```

- [ ] **Step 4: Wrap the existing return JSX**

```tsx
return (
  <div ref={readerRootRef} className="relative h-full">
    {/* existing Azw3View JSX */}
    <NavigationHistoryFooter />
  </div>
)
```

- [ ] **Step 5: Intercept body link clicks**

If `Azw3View` uses an epub.js-like rendition with `rendition.hooks.content.register`, add the same iframe click handler as Task 15 Step 1, but use `kind: formatKind` in both `from` and `to` position descriptors.

If the renderer is not epub.js-based, attach a `click` listener to the rendered content's root element (find this in the existing render method). The handler should:
1. Find the closest `<a href>` ancestor
2. Skip external links (`^(https?:|mailto:)`)
3. Read the current position (CFI or analog)
4. Dispatch `JUMP_REQUESTED` with `source: 'link'`
5. Call the renderer's navigation method to follow the link

```typescript
function interceptLinkClick(event: Event, currentCfi: string): void {
  const target = event.target as HTMLElement | null
  const anchor = target?.closest('a[href]') as HTMLAnchorElement | null
  if (!anchor) return
  const href = anchor.getAttribute('href')
  if (!href || /^(https?:|mailto:)/i.test(href)) return
  event.preventDefault()
  const ttsParagraph = usePlayerStore.getState().activeParagraph
  navigationHistoryActor.send({
    type: 'JUMP_REQUESTED',
    from: { kind: formatKind, cfi: currentCfi },
    fromTts: ttsParagraph != null ? { paragraphIndex: ttsParagraph } : null,
    to: { kind: formatKind, cfi: href },
    source: 'link',
    fromLabel: 'previous spot'
  })
  /* call renderer's display method */
}
```

- [ ] **Step 6: Wrap TOC/bookmark click handlers**

Find the existing TOC and bookmark click handlers in `Azw3View.tsx`. For each, wrap the navigation call with a `JUMP_REQUESTED` dispatch using `source: 'toc'` or `'bookmark'`, matching the EPUB pattern in Task 15 Step 2.

- [ ] **Step 7: Manual smoke test with a MOBI and an AZW3 file**

Run: `pnpm dev`
For both an AZW3 and a MOBI file:
1. Open book → click an internal link → pill appears
2. Click pill → returns to prior position
3. Open TOC → click an entry → pill → click pill → back
4. Page-flip without engagement → return restores initial position

- [ ] **Step 8: Run all tests, no regressions**

Run: `pnpm test`
Expected: green.

- [ ] **Step 9: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/azw3/
git commit -m "feat(electron): wire AZW3/MOBI reader to navigation history"
```

---

## Phase 5 — E2E coverage

### Task 17: E2E test — EPUB jump + back

**Files:**
- Create: `apps/rishi-electron/e2e/navigation-history-epub.spec.ts`

Use the pattern from `apps/rishi-electron/e2e/tts-page-navigation.spec.ts`.

- [ ] **Step 1: Write the test**

```typescript
// apps/rishi-electron/e2e/navigation-history-epub.spec.ts
import { test, expect } from '@playwright/test'
import { openBook, importEpub } from './helpers/library' // existing helpers

test.describe('EPUB navigation history', () => {
  test('link click → pill appears → pop returns to original CFI', async ({ page }) => {
    await importEpub(page, 'fixtures/footnote-book.epub')
    await openBook(page, 'footnote-book')

    // Read initial CFI
    const initialCfi = await page.evaluate(() => (window as any).__currentCfi)

    // Click an internal footnote link inside the rendered iframe
    const iframe = page.frameLocator('iframe').first()
    await iframe.locator('a[href*="#footnote"]').first().click()

    // Pill appears
    const pill = page.getByRole('status').filter({ hasText: /Back to/ })
    await expect(pill).toBeVisible({ timeout: 2000 })

    // Pop back
    await pill.click()

    // Pill disappears, CFI restored
    await expect(pill).toBeHidden()
    const finalCfi = await page.evaluate(() => (window as any).__currentCfi)
    expect(finalCfi).toBe(initialCfi)
  })

  test('TOC click → pill → pop returns to original position', async ({ page }) => {
    await importEpub(page, 'fixtures/toc-book.epub')
    await openBook(page, 'toc-book')

    const initialCfi = await page.evaluate(() => (window as any).__currentCfi)

    await page.getByRole('button', { name: /toc|contents/i }).click()
    await page.getByRole('link').nth(2).click() // jump to 3rd TOC entry

    const pill = page.getByRole('status').filter({ hasText: /Back to/ })
    await expect(pill).toBeVisible()
    await pill.click()
    await expect(pill).toBeHidden()

    const finalCfi = await page.evaluate(() => (window as any).__currentCfi)
    expect(finalCfi).toBe(initialCfi)
  })

  test('page-flip without engagement → return restores natural position (no pill)', async ({ page }) => {
    await importEpub(page, 'fixtures/long-book.epub')
    await openBook(page, 'long-book')

    const initialCfi = await page.evaluate(() => (window as any).__currentCfi)

    // No engagement; just flip forward 3 pages and back
    await page.keyboard.press('ArrowRight')
    await page.keyboard.press('ArrowRight')
    await page.keyboard.press('ArrowRight')
    await page.keyboard.press('ArrowLeft')
    await page.keyboard.press('ArrowLeft')
    await page.keyboard.press('ArrowLeft')

    // Pill never appeared
    await expect(page.getByRole('status')).toBeHidden()

    const finalCfi = await page.evaluate(() => (window as any).__currentCfi)
    expect(finalCfi).toBe(initialCfi)
  })
})
```

> **Note:** the test relies on the renderer exposing `window.__currentCfi` for diagnostic readback. If that isn't already exposed, add it in `EpubView` development builds gated by `import.meta.env.DEV`. Alternative: use a data attribute on the reader root reflecting the current CFI.

- [ ] **Step 2: Add a footnote-book fixture if not present**

Check `apps/rishi-electron/e2e/fixtures/`. If no suitable EPUB exists, add a tiny generated one (use `epub-gen` or check for an existing test EPUB in `apps/mobile/test-recordings/` or `examples/`).

- [ ] **Step 3: Run the E2E**

Run: `pnpm exec playwright test e2e/navigation-history-epub.spec.ts`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/e2e/
git commit -m "test(electron): E2E for EPUB navigation history (links, TOC, page-flip)"
```

---

### Task 18: E2E test — PDF jump + back + resume

**Files:**
- Create: `apps/rishi-electron/e2e/navigation-history-pdf.spec.ts`

- [ ] **Step 1: Write the test**

Mirror Task 17's structure for PDF:

```typescript
import { test, expect } from '@playwright/test'
import { openBook, importPdf } from './helpers/library'

test.describe('PDF navigation history', () => {
  test('TOC click → pill → pop returns to original page + scroll offset', async ({ page }) => {
    await importPdf(page, 'fixtures/manual-with-toc.pdf')
    await openBook(page, 'manual-with-toc')

    // Scroll within page 1
    await page.locator('.react-pdf__Page').first().evaluate((el) => (el as HTMLElement).scrollTop = 200)

    const initialOffset = await page.evaluate(() => (window as any).__currentPdfOffset)
    const initialPage = await page.evaluate(() => (window as any).__currentPdfPage)

    await page.getByRole('button', { name: /toc|contents/i }).click()
    await page.getByRole('link').nth(2).click()

    const pill = page.getByRole('status').filter({ hasText: /Back to/ })
    await expect(pill).toBeVisible()
    await pill.click()

    const finalOffset = await page.evaluate(() => (window as any).__currentPdfOffset)
    const finalPage = await page.evaluate(() => (window as any).__currentPdfPage)
    expect(finalPage).toBe(initialPage)
    expect(Math.abs(finalOffset - initialOffset)).toBeLessThan(20) // tolerate small layout drift
  })

  test('tap on destination page → on return, lands at tapped spot not original', async ({ page }) => {
    await importPdf(page, 'fixtures/long.pdf')
    await openBook(page, 'long')

    // Engage on page 1 (tap)
    await page.locator('.react-pdf__Page').first().click({ position: { x: 100, y: 200 } })
    await page.waitForTimeout(100)

    // Flip to page 5
    await page.keyboard.press('PageDown')
    await page.keyboard.press('PageDown')
    await page.keyboard.press('PageDown')
    await page.keyboard.press('PageDown')

    // Engage on page 5 (tap)
    await page.locator('.react-pdf__Page').nth(0).click({ position: { x: 100, y: 200 } })
    const engagedPage = await page.evaluate(() => (window as any).__currentPdfPage)

    // Flip away then back to page 5's vicinity
    await page.keyboard.press('PageUp')
    await page.keyboard.press('PageDown')

    const finalPage = await page.evaluate(() => (window as any).__currentPdfPage)
    expect(finalPage).toBe(engagedPage)
  })
})
```

- [ ] **Step 2: Add `window.__currentPdfPage` / `__currentPdfOffset` diagnostic in dev**

In `pdf.tsx` inside `import.meta.env.DEV` guard:

```typescript
useEffect(() => {
  if (import.meta.env.DEV) {
    (window as unknown as { __currentPdfPage: number }).__currentPdfPage = pdfReader.currentPage
    ;(window as unknown as { __currentPdfOffset: number }).__currentPdfOffset = pdfReader.currentOffset ?? 0
  }
}, [pdfReader.currentPage, pdfReader.currentOffset])
```

- [ ] **Step 3: Run the E2E**

Run: `pnpm exec playwright test e2e/navigation-history-pdf.spec.ts`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/e2e/ apps/rishi-electron/src/renderer/src/components/pdf/
git commit -m "test(electron): E2E for PDF navigation history (TOC, engagement resume)"
```

---

### Task 19: Full test suite + manual QA pass

- [ ] **Step 1: Run full unit + integration suite**

Run: `pnpm --filter rishi-electron test`
Expected: all green.

- [ ] **Step 2: Run full E2E suite**

Run: `pnpm --filter rishi-electron exec playwright test`
Expected: all green.

- [ ] **Step 3: Manual QA — golden path per format**

For each of EPUB, PDF, AZW3, MOBI:
1. Open book → click an internal link → pill appears with prior-spot label
2. Tap pill → returns to prior spot (CFI/page+offset matches)
3. Engage on destination (tap, select, or play TTS) → pill fades but stack entry retained
4. Press Cmd/Ctrl+[ → pops back even with pill hidden
5. Chain 3 jumps → pill shows depth (3), pop back one by one
6. Page-flip without engagement → return restores initial position (no pill ever shown)
7. Page-flip *with* engagement → return restores engaged position

- [ ] **Step 4: Verify no regressions in existing reader tests**

Re-run: `pnpm test e2e/tts-page-navigation.spec.ts`
Expected: green.

- [ ] **Step 5: Final commit if any docs / cleanup needed**

```bash
git status
# add any final docs or test fixture updates
git commit -m "chore(electron): navigation history QA pass"
```

---

## Out of Scope (do NOT implement)

- Forward stack
- Persisting back stack across app restarts
- `partialOffset` mid-paragraph TTS resume
- Visual history viewer
- Cross-book navigation
- Web / mobile clients

## Verification Checklist (before declaring "done")

- [ ] All unit tests pass (`pnpm test`)
- [ ] All E2E tests pass (`pnpm exec playwright test`)
- [ ] Per-format manual QA completed (Task 19 Step 3)
- [ ] No type errors (`pnpm exec tsc --noEmit -p tsconfig.web.json`)
- [ ] No new lint warnings in modified files
- [ ] Spec coverage: every section of `docs/superpowers/specs/2026-05-21-reader-navigation-history-design.md` maps to at least one task above
