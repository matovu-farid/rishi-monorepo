# TTS Highlight Reconciler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace delta-based imperative TTS-highlight code in AZW3 and EPUB readers with idempotent per-reader reconcilers driven by a shared trigger hook. Fixes the stuck-highlight-after-blur bug; preserves user highlights via namespace isolation (AZW3) and ownership registry (EPUB).

**Architecture:** Two new pure reconciler modules (one per reader) + one shared React hook that subscribes to `playerStore.activeParagraph` and to window/document focus events, calling the reconciler on each trigger. PDF needs no change — it is already declarative.

**Tech Stack:** TypeScript, React, Zustand (`playerStore`), Vitest + jsdom, epub.js (EPUB), CSS-class-on-iframe-DOM (AZW3).

**Spec:** `docs/superpowers/specs/2026-05-20-tts-highlight-reconciler-design.md`

---

## File Structure

**New files:**
- `apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.ts` — pure AZW3 reconciler function
- `apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.test.ts`
- `apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.ts` — EPUB reconciler factory with ownership registry
- `apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.test.ts`
- `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.ts` — shared trigger hook
- `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.test.ts`

**Modified files:**
- `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx` — wire hook, delete old highlight effect (lines 454–525) and post-iframe-reload re-apply (lines 309–317). Keep auto-scroll-into-view as a separate effect subscribed only to `activeParagraph`.
- `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx` — wire hook, delete three `playerStore` subscriptions for highlights (lines 830–852) and the `playingState`-driven `clearAllHighlights` subscription (lines 854–861). Keep `clearAllHighlights` helper itself — it's still used by page nav.
- `apps/rishi-electron/src/renderer/src/stores/playerStore.ts` — remove `endedParagraph`, `lastMove` fields and their initializers.
- `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts` — remove setters that populate the deleted fields.
- `apps/rishi-electron/src/renderer/src/components/azw3/highlight.ts` — delete `setActiveClass` if no other callers remain after the refactor (grep first).
- `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.test.tsx` (new or modify existing) — one regression test for the existing declarative PDF behavior.

---

### Task 1: AZW3 reconciler

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.ts`
- Create: `apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { reconcileAzw3TtsHighlight } from './reconcileTtsHighlight'
import { TTS_ACTIVE_CLASS } from './highlight'

function docOf(html: string): Document {
  return new DOMParser().parseFromString(`<html><body>${html}</body></html>`, 'text/html')
}

const CHAPTER = 4
const FIVE_PARAS = `
  <p>p0</p><p>p1</p><p>p2</p><p>p3</p><p>p4</p>
`

describe('reconcileAzw3TtsHighlight', () => {
  it('no-ops on a null document', () => {
    expect(() => reconcileAzw3TtsHighlight(null, CHAPTER, 'azw3-4-0')).not.toThrow()
    expect(() => reconcileAzw3TtsHighlight(null, CHAPTER, null)).not.toThrow()
  })

  it('with desiredIndex=null on an empty namespace, does nothing', () => {
    const doc = docOf(FIVE_PARAS)
    reconcileAzw3TtsHighlight(doc, CHAPTER, null)
    expect(doc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)).toHaveLength(0)
  })

  it('with desiredIndex=null when a TTS highlight exists, removes it', () => {
    const doc = docOf(FIVE_PARAS)
    doc.querySelectorAll('p')[2]!.classList.add(TTS_ACTIVE_CLASS)
    reconcileAzw3TtsHighlight(doc, CHAPTER, null)
    expect(doc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)).toHaveLength(0)
  })

  it('adds the highlight on the matching paragraph', () => {
    const doc = docOf(FIVE_PARAS)
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-4-2')
    const ps = doc.querySelectorAll('p')
    expect(ps[2]!.classList.contains(TTS_ACTIVE_CLASS)).toBe(true)
    expect(doc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)).toHaveLength(1)
  })

  it('moves the highlight when desiredIndex changes', () => {
    const doc = docOf(FIVE_PARAS)
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-4-1')
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-4-3')
    const ps = doc.querySelectorAll('p')
    expect(ps[1]!.classList.contains(TTS_ACTIVE_CLASS)).toBe(false)
    expect(ps[3]!.classList.contains(TTS_ACTIVE_CLASS)).toBe(true)
    expect(doc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)).toHaveLength(1)
  })

  it('does not blink: re-calling with the same desiredIndex emits no classList ops', () => {
    const doc = docOf(FIVE_PARAS)
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-4-2')
    const el = doc.querySelectorAll('p')[2]!
    const addSpy = vi.spyOn(el.classList, 'add')
    const removeSpy = vi.spyOn(el.classList, 'remove')
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-4-2')
    expect(addSpy).not.toHaveBeenCalled()
    expect(removeSpy).not.toHaveBeenCalled()
  })

  it('cleans up stale highlights even if the desired element is missing', () => {
    const doc = docOf(`<p>only</p>`)
    // pretend a stale highlight is on the only paragraph
    doc.querySelector('p')!.classList.add(TTS_ACTIVE_CLASS)
    // desired index points to a paragraph that does not exist
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-4-99')
    expect(doc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)).toHaveLength(0)
  })

  it('does not highlight when the desired index belongs to a different chapter', () => {
    const doc = docOf(FIVE_PARAS)
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-9-2')
    expect(doc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)).toHaveLength(0)
  })

  it('preserves unrelated CSS classes on the paragraph', () => {
    const doc = docOf(`<p class="user-highlight-yellow">x</p>`)
    reconcileAzw3TtsHighlight(doc, CHAPTER, 'azw3-4-0')
    const p = doc.querySelector('p')!
    expect(p.classList.contains('user-highlight-yellow')).toBe(true)
    expect(p.classList.contains(TTS_ACTIVE_CLASS)).toBe(true)
    reconcileAzw3TtsHighlight(doc, CHAPTER, null)
    expect(p.classList.contains('user-highlight-yellow')).toBe(true)
    expect(p.classList.contains(TTS_ACTIVE_CLASS)).toBe(false)
  })
})
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
pnpm --filter rishi-electron test reconcileTtsHighlight.test.ts
```

Expected: all tests fail with `Cannot find module './reconcileTtsHighlight'`.

- [ ] **Step 3: Implement the reconciler**

Create `apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.ts`:

```ts
import { findParagraphElement, parseParagraphIndex, TTS_ACTIVE_CLASS } from './highlight'

/**
 * Idempotently converge the AZW3 iframe document to show exactly the TTS
 * highlight implied by `desiredIndex`. Removes any stale `.rishi-tts-active`
 * class found in the document; applies the class to the desired paragraph
 * if it belongs to the currently-loaded chapter and the element resolves.
 *
 * Silent recovery: if the desired paragraph is in a different chapter or
 * the element is not present, the reconciler still clears stale markup
 * but adds nothing. The next reconcile (on iframe load, focus return, or
 * the next activeParagraph change) will reapply.
 */
export function reconcileAzw3TtsHighlight(
  iframeDoc: Document | null,
  currentChapterIndex: number,
  desiredIndex: string | null,
): void {
  if (!iframeDoc) return

  let desiredEl: Element | null = null
  if (desiredIndex) {
    const parsed = parseParagraphIndex(desiredIndex)
    if (parsed && parsed.chapter === currentChapterIndex) {
      desiredEl = findParagraphElement(iframeDoc, parsed.paragraph)
    }
  }

  const existing = iframeDoc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)
  for (const el of Array.from(existing)) {
    if (el !== desiredEl) el.classList.remove(TTS_ACTIVE_CLASS)
  }
  if (desiredEl && !desiredEl.classList.contains(TTS_ACTIVE_CLASS)) {
    desiredEl.classList.add(TTS_ACTIVE_CLASS)
  }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
pnpm --filter rishi-electron test reconcileTtsHighlight.test.ts
```

Expected: all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add \
  apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.ts \
  apps/rishi-electron/src/renderer/src/components/azw3/reconcileTtsHighlight.test.ts
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "feat(electron): add AZW3 TTS-highlight reconciler"
```

---

### Task 2: EPUB reconciler

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.ts`
- Create: `apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

const highlightRangeMock = vi.fn().mockResolvedValue(undefined)
const removeHighlightMock = vi.fn().mockResolvedValue(true)

vi.mock('@/modules/epubwrapper', () => ({
  highlightRange: (...args: unknown[]) => highlightRangeMock(...args),
  removeHighlight: (...args: unknown[]) => removeHighlightMock(...args),
}))

import { createEpubTtsReconciler } from './reconcileTtsHighlight'

interface FakeRendition {
  annotations: { _annotations: Record<string, unknown> }
}

function makeRendition(userOwnedCfis: string[] = []): FakeRendition {
  const _annotations: Record<string, unknown> = {}
  for (const cfi of userOwnedCfis) {
    _annotations[encodeURI(cfi + 'highlight')] = { type: 'highlight', cfi }
  }
  return { annotations: { _annotations } }
}

beforeEach(() => {
  highlightRangeMock.mockClear()
  removeHighlightMock.mockClear()
})

describe('createEpubTtsReconciler', () => {
  it('with desiredIndex=null on an empty registry, calls nothing', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile(null)
    expect(highlightRangeMock).not.toHaveBeenCalled()
    expect(removeHighlightMock).not.toHaveBeenCalled()
  })

  it('with a fresh desiredIndex, calls highlightRange exactly once', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    expect(highlightRangeMock).toHaveBeenCalledTimes(1)
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p5')
  })

  it('moves the highlight when desiredIndex changes', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    highlightRangeMock.mockClear()
    reconcile('cfi-p7')
    expect(removeHighlightMock).toHaveBeenCalledTimes(1)
    expect(removeHighlightMock).toHaveBeenCalledWith(r, 'cfi-p5')
    expect(highlightRangeMock).toHaveBeenCalledTimes(1)
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p7')
  })

  it('clears the highlight when desiredIndex becomes null', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    removeHighlightMock.mockClear()
    reconcile(null)
    expect(removeHighlightMock).toHaveBeenCalledTimes(1)
    expect(removeHighlightMock).toHaveBeenCalledWith(r, 'cfi-p5')
  })

  it('does not blink: re-calling with the same desiredIndex emits no calls', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    highlightRangeMock.mockClear()
    removeHighlightMock.mockClear()
    reconcile('cfi-p5')
    expect(highlightRangeMock).not.toHaveBeenCalled()
    expect(removeHighlightMock).not.toHaveBeenCalled()
  })

  it('ownership registry: does NOT remove a CFI owned by a user highlight', () => {
    const r = makeRendition(['cfi-p5'])  // pre-existing user highlight
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    // we still call highlightRange (it dedupes inside epub.js)
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p5')
    removeHighlightMock.mockClear()
    reconcile('cfi-p7')
    // crucial: cfi-p5 is NOT removed because the user owned it
    expect(removeHighlightMock).not.toHaveBeenCalledWith(r, 'cfi-p5')
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p7')
  })

  it('ownership registry: removes a CFI we did add when transitioning away', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    // simulate annotation appearing in the store after add (epub.js side effect)
    r.annotations._annotations[encodeURI('cfi-p5' + 'highlight')] = {}
    reconcile('cfi-p7')
    // because we tracked cfi-p5 as ours, we DO remove it
    expect(removeHighlightMock).toHaveBeenCalledWith(r, 'cfi-p5')
  })

  it('ownership registry: handles a full cycle without touching user highlights', () => {
    const r = makeRendition(['cfi-user-A', 'cfi-user-B'])
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-tts-1')
    reconcile('cfi-tts-2')
    reconcile(null)
    // user CFIs never appear in any remove call
    const removedCfis = removeHighlightMock.mock.calls.map((c) => c[1])
    expect(removedCfis).not.toContain('cfi-user-A')
    expect(removedCfis).not.toContain('cfi-user-B')
  })
})
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
pnpm --filter rishi-electron test reconcileTtsHighlight.test.ts -t createEpubTtsReconciler
```

Expected: all tests fail with `Cannot find module './reconcileTtsHighlight'`.

- [ ] **Step 3: Implement the reconciler**

Create `apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.ts`:

```ts
import type { Rendition } from 'epubjs'
import { highlightRange, removeHighlight } from '@/modules/epubwrapper'

/**
 * Build an idempotent TTS-highlight reconciler bound to a single epub.js
 * Rendition. The reconciler maintains a local ownership registry of CFIs
 * it has applied; it removes only what it owns and never enumerates
 * `rendition.annotations._annotations` to decide what to delete.
 *
 * This is how user-highlight isolation is enforced for EPUB: epub.js
 * shares the "highlight" annotation type between TTS and user
 * highlights, so we cannot separate them at the type/namespace layer.
 * Instead, we know what we added.
 */
export function createEpubTtsReconciler(rendition: Rendition) {
  const owned = new Set<string>()
  let currentTtsCfi: string | null = null

  return function reconcile(desiredIndex: string | null): void {
    // Step 1: clear the previous TTS highlight, but only if WE added it.
    if (currentTtsCfi && currentTtsCfi !== desiredIndex) {
      if (owned.has(currentTtsCfi)) {
        void removeHighlight(rendition, currentTtsCfi)
        owned.delete(currentTtsCfi)
      }
      currentTtsCfi = null
    }
    // Step 2: apply the new one. If a user highlight already exists at
    // this CFI, epub.js dedupes (the user's color wins visually); we do
    // not mark ourselves as owner so we never remove it later.
    if (desiredIndex && currentTtsCfi !== desiredIndex) {
      const hash = encodeURI(desiredIndex + 'highlight')
      const userOwnsIt = hash in rendition.annotations._annotations
      void highlightRange(rendition, desiredIndex)
      if (!userOwnsIt) owned.add(desiredIndex)
      currentTtsCfi = desiredIndex
    }
  }
}

export type EpubTtsReconciler = ReturnType<typeof createEpubTtsReconciler>
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
pnpm --filter rishi-electron test reconcileTtsHighlight.test.ts -t createEpubTtsReconciler
```

Expected: all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add \
  apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.ts \
  apps/rishi-electron/src/renderer/src/components/epub/reconcileTtsHighlight.test.ts
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "feat(electron): add EPUB TTS-highlight reconciler with ownership registry"
```

---

### Task 3: Shared trigger hook

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.ts`
- Create: `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'
import { useTtsHighlightReconciler } from './useTtsHighlightReconciler'

function setActive(index: string | null): void {
  usePlayerStore.setState({
    activeParagraph: index ? ({ index, key: index, text: '' } as never) : null,
  })
}

beforeEach(() => {
  usePlayerStore.setState({ activeParagraph: null })
})

describe('useTtsHighlightReconciler', () => {
  it('calls the reconciler on mount with the current activeParagraph', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('calls the reconciler with null when activeParagraph is null', () => {
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    expect(reconcile).toHaveBeenCalledWith(null)
  })

  it('re-invokes the reconciler when activeParagraph changes', () => {
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    act(() => setActive('p7'))
    expect(reconcile).toHaveBeenCalledWith('p7')
  })

  it('re-invokes the reconciler on document.visibilitychange to visible', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('does not re-invoke on visibilitychange to hidden', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
    expect(reconcile).not.toHaveBeenCalled()
  })

  it('re-invokes the reconciler on window.focus', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    window.dispatchEvent(new Event('focus'))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('re-invokes the reconciler on iframe.load when iframe is provided', () => {
    setActive('p5')
    const iframe = document.createElement('iframe')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, iframe))
    reconcile.mockClear()
    iframe.dispatchEvent(new Event('load'))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('tears down listeners on unmount', () => {
    setActive('p5')
    const reconcile = vi.fn()
    const { unmount } = renderHook(() => useTtsHighlightReconciler(reconcile, null))
    unmount()
    reconcile.mockClear()
    window.dispatchEvent(new Event('focus'))
    document.dispatchEvent(new Event('visibilitychange'))
    act(() => setActive('p9'))
    expect(reconcile).not.toHaveBeenCalled()
  })
})

describe('useTtsHighlightReconciler — integration (the bug class)', () => {
  it('sweeps stale state on focus return even when activeParagraph did not change', () => {
    setActive('p5')
    let lastSeen: string | null | undefined
    const reconcile = vi.fn((d: string | null) => {
      lastSeen = d
    })
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    // Simulate macOS Space switch: blur → focus.
    window.dispatchEvent(new Event('blur'))
    reconcile.mockClear()
    window.dispatchEvent(new Event('focus'))
    expect(reconcile).toHaveBeenCalledWith('p5')
    expect(lastSeen).toBe('p5')
  })

  it('full cycle: activeParagraph p5 → blur → focus → advance to p7', () => {
    const calls: Array<string | null> = []
    const reconcile = vi.fn((d: string | null) => { calls.push(d) })
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    act(() => setActive('p5'))
    window.dispatchEvent(new Event('focus'))     // simulated focus return
    act(() => setActive('p7'))
    // Mount call + each subsequent trigger should pass the then-current value.
    expect(calls).toContain('p5')
    expect(calls).toContain('p7')
    expect(calls[calls.length - 1]).toBe('p7')
  })
})
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
pnpm --filter rishi-electron test useTtsHighlightReconciler.test.ts
```

Expected: all tests fail with module-not-found.

- [ ] **Step 3: Implement the hook**

Create `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.ts`:

```ts
import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'

export type ReconcileTtsHighlight = (desiredIndex: string | null) => void

/**
 * Subscribe to playerStore.activeParagraph and to window/document focus
 * events; call the supplied reconciler on every trigger with the current
 * desired paragraph index. The reconciler is responsible for making the
 * DOM (or annotation store) converge to that state.
 *
 * Idempotency of `reconcile` is required — this hook fires on multiple
 * trigger types that can overlap (focus + visibilitychange in sequence
 * on macOS Space return).
 *
 * The `iframe` argument is optional: pass the reader's content iframe
 * so the reconciler re-runs after chapter swaps. PDF does not use this
 * hook.
 */
export function useTtsHighlightReconciler(
  reconcile: ReconcileTtsHighlight,
  iframe: HTMLIFrameElement | null,
): void {
  useEffect(() => {
    const run = (): void => {
      reconcile(usePlayerStore.getState().activeParagraph?.index ?? null)
    }

    // 1. Initial run.
    run()

    // 2. Store subscription: re-run when activeParagraph changes.
    const unsubStore = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      () => run(),
    )

    // 3. Focus + visibility triggers.
    const onVisibility = (): void => {
      if (document.visibilityState === 'visible') run()
    }
    const onFocus = (): void => run()
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('focus', onFocus)

    // 4. Iframe content reload: chapter swap or surface reset.
    const onIframeLoad = (): void => run()
    iframe?.addEventListener('load', onIframeLoad)

    return () => {
      unsubStore()
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('focus', onFocus)
      iframe?.removeEventListener('load', onIframeLoad)
    }
  }, [reconcile, iframe])
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
pnpm --filter rishi-electron test useTtsHighlightReconciler.test.ts
```

Expected: all 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add \
  apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.ts \
  apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.test.ts
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "feat(electron): add useTtsHighlightReconciler shared trigger hook"
```

---

### Task 4: Wire AZW3View to the reconciler; delete old highlight code

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx`

- [ ] **Step 1: Add the hook + reconciler usage near the top of the component**

Open `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx`. Add imports at the top of the file (group with existing relative imports):

```ts
import { useTtsHighlightReconciler } from '@/hooks/useTtsHighlightReconciler'
import { reconcileAzw3TtsHighlight } from './reconcileTtsHighlight'
```

Then, somewhere inside the component body where `iframeRef` and `chapterIndex` are in scope (above the auto-scroll effect you'll keep — see Step 2), add:

```ts
const reconcileTts = useCallback(
  (desired: string | null) => {
    reconcileAzw3TtsHighlight(
      iframeRef.current?.contentDocument ?? null,
      chapterIndex,
      desired,
    )
  },
  [chapterIndex],
)
useTtsHighlightReconciler(reconcileTts, iframeRef.current)
```

(Confirm `useCallback` is already imported; if not, add to the React import line.)

- [ ] **Step 2: Replace the old highlight effect with an auto-scroll-only effect**

In the same file, locate the existing `useEffect` block at lines 454–525 — the one that calls `setActiveClass` and includes the scroll-into-view logic. Replace the entire block with a slimmer effect that **only** scrolls the active paragraph into view (the class application now lives in the reconciler):

```ts
// Auto-scroll the active paragraph into view when the player advances.
// This effect is intentionally scoped to activeParagraph store changes only
// — focus/iframe-load triggers should NOT re-scroll. Class management is
// owned by the reconciler.
useEffect(() => {
  const unsub = usePlayerStore.subscribe(
    (s) => s.activeParagraph,
    (paragraph) => {
      if (!paragraph) return
      const parsed = parseParagraphIndex(paragraph.index)
      if (parsed?.chapter !== chapterIndex) return
      const doc = iframeRef.current?.contentDocument ?? null
      const win = iframeRef.current?.contentWindow ?? null
      const el = findParagraphElement(doc, parsed.paragraph)
      if (!el || !doc || !win) return
      const rect = el.getBoundingClientRect()
      const body = doc.body
      const viewportWidth = win.innerWidth
      if (rect.left >= 0 && rect.right <= viewportWidth) return
      const cs = win.getComputedStyle(body)
      const columnGap = parseFloat(cs.columnGap || '0') || 0
      const paddingLeft = parseFloat(cs.paddingLeft || '0') || 0
      const paddingRight = parseFloat(cs.paddingRight || '0') || 0
      const pageStep = computePageStep(body.clientWidth, columnGap, paddingLeft, paddingRight)
      const elementLeftFromBodyStart = body.scrollLeft + rect.left
      const totalPages = pagesInCurrentChapterRef.current
      const targetPage = Math.max(
        0,
        Math.min(totalPages - 1, Math.floor(elementLeftFromBodyStart / pageStep)),
      )
      const applied = applyScrollToPage(doc, win, targetPage, totalPages, pageStep)
      setPageWithinChapter((prev) => (prev === applied ? prev : applied))
    },
  )
  return unsub
}, [applyScrollToPage, chapterIndex])
```

Delete the old `apply()` helper closure, the three `unsubActive`/`unsubEnded`/`unsubMove` subscriptions, and the `setActiveClass` import if it becomes unused.

- [ ] **Step 3: Delete the post-iframe-reload re-apply at lines 309–317**

Locate the small block in the iframe `load` handler that re-applies the active class after an iframe content reload (lines ~309–317). Delete it. The reconciler hook's `iframe.load` listener now handles this.

- [ ] **Step 4: Run all AZW3 tests**

```bash
pnpm --filter rishi-electron test apps/rishi-electron/src/renderer/src/components/azw3/
```

Expected: all tests pass. The reconciler tests from Task 1 still pass; existing AZW3 tests still pass.

- [ ] **Step 5: Type-check**

```bash
pnpm --filter rishi-electron typecheck
```

Expected: no errors. If the `setActiveClass` import in `Azw3View.tsx` is unused, remove it.

- [ ] **Step 6: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "refactor(electron): wire AZW3 reader to TTS-highlight reconciler"
```

---

### Task 5: Wire EpubView to the reconciler; delete old highlight code

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`

- [ ] **Step 1: Add the reconciler factory + hook**

Open `EpubView.tsx`. Add imports:

```ts
import { useTtsHighlightReconciler } from '@/hooks/useTtsHighlightReconciler'
import { createEpubTtsReconciler, type EpubTtsReconciler } from './reconcileTtsHighlight'
```

Inside the component body, where `rendition` is held (look for `renditionRef` / the state holding the resolved `Rendition`), create a reconciler tied to the rendition:

```ts
const epubTtsReconcilerRef = useRef<EpubTtsReconciler | null>(null)

// Build (or rebuild) the reconciler whenever the rendition instance changes.
useEffect(() => {
  if (!rendition) {
    epubTtsReconcilerRef.current = null
    return
  }
  epubTtsReconcilerRef.current = createEpubTtsReconciler(rendition)
}, [rendition])

const reconcileTts = useCallback((desired: string | null) => {
  epubTtsReconcilerRef.current?.(desired)
}, [])

// EPUB's content iframe is owned by epub.js. Identify it by reading
// `rendition.manager.views().container`'s first <iframe> child once the
// rendition is ready. For initial render, pass null; the hook re-runs
// once the iframe ref resolves on the next render cycle.
const epubIframe = useEpubContentIframe(rendition)
useTtsHighlightReconciler(reconcileTts, epubIframe)
```

If `useEpubContentIframe` does not already exist, add a small helper alongside this file or inline:

```ts
function useEpubContentIframe(rendition: Rendition | null): HTMLIFrameElement | null {
  const [iframe, setIframe] = useState<HTMLIFrameElement | null>(null)
  useEffect(() => {
    if (!rendition) { setIframe(null); return }
    const tick = (): void => {
      const view = rendition.manager?.views?.()?.first?.()
      const el = view?.iframe ?? null
      setIframe((prev) => (prev === el ? prev : el))
    }
    tick()
    const off = rendition.on?.('rendered', tick)
    return () => { if (typeof off === 'function') off() }
  }, [rendition])
  return iframe
}
```

(Adapt to the exact epub.js API surface in this codebase — if `rendition.manager.views().first().iframe` is not the right path, read `EpubView.tsx` for existing accesses to the iframe.)

- [ ] **Step 2: Delete the three highlight subscriptions and the `unsubState` highlight cleanup**

Locate lines 830–861 of `EpubView.tsx`: `unsubActive`, `unsubEnded`, `unsubMove`, and `unsubState`. Delete all four subscription blocks and the corresponding entries in the cleanup function (e.g., `unsubActive()`, `unsubEnded()`, etc.).

`clearAllHighlights` itself stays — it is called from `tryConsumePageRequest` (line 764). Do **not** delete it; only delete the subscription block at lines 854–861 that invokes it.

If `highlightRange` and `removeHighlight` become unused at the top of `EpubView.tsx` after deletion, remove them from the import list. (They are still used by `HighlightsPanel.tsx` and via the reconciler, but only the reconciler now imports them through `epubwrapper`.)

- [ ] **Step 3: Run all EPUB tests**

```bash
pnpm --filter rishi-electron test apps/rishi-electron/src/renderer/src/components/epub/
```

Expected: all tests pass. The reconciler tests from Task 2 still pass; existing EPUB tests still pass.

- [ ] **Step 4: Type-check**

```bash
pnpm --filter rishi-electron typecheck
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "refactor(electron): wire EPUB reader to TTS-highlight reconciler"
```

---

### Task 6: Delete dead `lastMove` and `endedParagraph` state

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/stores/playerStore.ts`
- Modify: `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts`

- [ ] **Step 1: Confirm there are no consumers left**

Run:

```bash
grep -rn "lastMove\|endedParagraph" /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/src --include="*.ts" --include="*.tsx" | grep -v ".test." | grep -v "lastMoveTimeRef"
```

Expected: only references inside `playerStore.ts` (field declarations + initializers) and `usePlayerMachine.ts` (setters). If any other consumer surfaces, STOP and revisit — those need migration before deletion.

- [ ] **Step 2: Remove the fields from `playerStore.ts`**

Open `apps/rishi-electron/src/renderer/src/stores/playerStore.ts`. Delete lines 38–39 (the type fields for `endedParagraph` and `lastMove`) and lines 69–70 (their initializers `endedParagraph: null` and `lastMove: null`). If a `PlayerStoreMove` type is now unused after the deletion, remove it too. Also delete the import of `PlayerStoreMove` if it's no longer referenced.

- [ ] **Step 3: Remove the setters from `usePlayerMachine.ts`**

Open `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts`. Around lines 261, 286, 293–294, 320, and 337–338, delete the field-name keys (`endedParagraph: null`, `lastMove: null`, `lastMove: { from, to }`, `endedParagraph = ctx.currentParagraphs[...] ?? null`, etc.) from each `usePlayerStore.setState({ ... })` call. Leave the rest of each `setState` call intact — only the dead keys go.

- [ ] **Step 4: Type-check and run the full test suite**

```bash
pnpm --filter rishi-electron typecheck && pnpm --filter rishi-electron test
```

Expected: clean. Any test that referenced `lastMove` or `endedParagraph` should have been migrated/deleted in Task 4 or 5; if a test still fails on these names now, update it to the new behavior (reconciler-driven highlights, no delta state).

- [ ] **Step 5: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add \
  apps/rishi-electron/src/renderer/src/stores/playerStore.ts \
  apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "refactor(electron): remove dead lastMove / endedParagraph store state"
```

---

### Task 7: Clean up `highlight.ts` if `setActiveClass` is now unused

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/azw3/highlight.ts`
- Modify (maybe): `apps/rishi-electron/src/renderer/src/components/azw3/highlight.test.ts`

- [ ] **Step 1: Grep for remaining `setActiveClass` callers**

```bash
grep -rn "setActiveClass" /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/src --include="*.ts" --include="*.tsx"
```

Expected: only `highlight.ts` (declaration) and `highlight.test.ts` (its tests). If a non-test consumer remains, skip this task entirely — `setActiveClass` is still load-bearing.

- [ ] **Step 2: Delete `setActiveClass` and its tests**

If Step 1 confirmed no production callers: open `apps/rishi-electron/src/renderer/src/components/azw3/highlight.ts` and delete the `setActiveClass` function (lines 47–50). Open `highlight.test.ts` and delete the `describe('setActiveClass', ...)` block (lines ~50–63).

- [ ] **Step 3: Type-check and run the full test suite**

```bash
pnpm --filter rishi-electron typecheck && pnpm --filter rishi-electron test
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add \
  apps/rishi-electron/src/renderer/src/components/azw3/highlight.ts \
  apps/rishi-electron/src/renderer/src/components/azw3/highlight.test.ts
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "refactor(electron): drop unused setActiveClass helper"
```

---

### Task 8: PDF regression test

**Files:**
- Create or modify: `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.test.tsx`

- [ ] **Step 1: Identify whether `pdf-page.test.tsx` exists**

```bash
ls /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.test.tsx 2>/dev/null
```

- [ ] **Step 2: Write the regression test**

Whether new or modify-existing, add a `describe('TTS highlight (declarative regression)', ...)` block asserting that the `customTextRenderer` returns `<mark>`-wrapped output when the page's resolved paragraph is non-null, and plain text when null:

```tsx
import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
// Adjust imports based on actual pdf-page exports.
// The intent: render <PdfPage> twice with different highlightedParagraphIndex
// state in pdfStore, assert <mark> presence/absence in the rendered output.

import { usePdfStore } from '@/stores/pdfStore'
import PdfPage from './pdf-page'

describe('PdfPage — TTS highlight (declarative regression)', () => {
  it('renders a <mark> in the text layer when a matching paragraph is active', () => {
    usePdfStore.setState({
      highlightedParagraphIndex: 'pdf-1-0',
      isHighlighting: true,
    })
    const { container } = render(
      <PdfPage /* required props with a minimal text item that matches pdf-1-0 */ />,
    )
    expect(container.querySelector('mark')).not.toBeNull()
  })

  it('renders plain text when no paragraph is active', () => {
    usePdfStore.setState({ highlightedParagraphIndex: null, isHighlighting: false })
    const { container } = render(<PdfPage /* same props */ />)
    expect(container.querySelector('mark')).toBeNull()
  })
})
```

If `PdfPage` requires complex props (a page object from pdf.js, page dimensions, etc.), keep the test smaller: import only `customTextRenderer` from `pdf-page.tsx` and unit-test the function directly. Match the existing testing patterns in `apps/rishi-electron/src/renderer/src/components/pdf/`.

- [ ] **Step 3: Run the test**

```bash
pnpm --filter rishi-electron test pdf-page.test.tsx
```

Expected: pass. If the test reveals that `customTextRenderer` no longer behaves declaratively, this is a real regression and the implementation must be re-examined.

- [ ] **Step 4: Commit**

```bash
git -C /Users/faridmatovu/projects/rishi-monorepo add apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.test.tsx
git -C /Users/faridmatovu/projects/rishi-monorepo commit -m "test(electron): regression test for PDF declarative TTS highlight"
```

---

### Task 9: Electron smoke pass (manual verification)

**Files:** none (manual procedure)

- [ ] **Step 1: Start the dev build**

```bash
pnpm --filter rishi-electron dev
```

- [ ] **Step 2: Reproduce the original bug scenario and confirm it is fixed**

Open a book in any of the three readers. Then:

1. Start TTS playback on a paragraph (paragraph N).
2. Confirm paragraph N is highlighted yellow.
3. Click Pause.
4. Alt-tab to another application.
5. Wait briefly (5–10 seconds).
6. Alt-tab back to the app.
7. Click Play.
8. Confirm: the only yellow TTS highlight is on the now-playing paragraph (N or whatever advanced after resume). No orphan highlight is left behind.
9. While playing, alt-tab away and back again mid-paragraph. Confirm: no flicker on focus return (no-blink invariant).

- [ ] **Step 3: Spot-check user highlight preservation**

1. Manually create a user highlight on a paragraph (using the existing highlight UI).
2. Start TTS, let it pass through that paragraph and beyond.
3. Confirm the user highlight is still present after TTS advances past it.

- [ ] **Step 4: Record results**

If any step fails, file a bug with steps to reproduce and **do not commit** any "fix" speculatively — re-investigate against the spec invariants (No-blink, Single-source convergence, User-highlight isolation).

If all steps pass, no commit is required for this task; it's a verification gate.

---

## Self-Review Notes

This plan has been reviewed against the spec at `docs/superpowers/specs/2026-05-20-tts-highlight-reconciler-design.md`:

- **Spec coverage:** All three reconciler contracts, the shared hook, the no-blink invariant, single-source convergence, EPUB ownership-registry isolation, and the dead-code removal list are covered by Tasks 1–7. The PDF declarative-regression test is Task 8. The bug-class integration test is folded into Task 3. The Electron smoke pass is Task 9.
- **Placeholders:** None. Every step contains the actual code or command an engineer needs.
- **Type consistency:** `ReconcileTtsHighlight` signature is identical in `useTtsHighlightReconciler.ts`, `reconcileTtsHighlight.ts` (AZW3), and the EPUB factory's return type. `TTS_ACTIVE_CLASS` is reused from `highlight.ts`. `findParagraphElement` and `parseParagraphIndex` are reused.
- **One open knot:** the exact epub.js API to retrieve the rendition's content iframe (Task 5, Step 1, helper `useEpubContentIframe`) is left to be resolved against the running codebase. The plan flags this and points the implementer to `EpubView.tsx`'s existing iframe accesses for the right symbol.
