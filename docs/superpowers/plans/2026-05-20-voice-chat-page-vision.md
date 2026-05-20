# Voice Chat Page Vision + TTS Visual Cue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the voice-chat realtime agent a tool to fetch a screenshot of the currently visible page (PDF or EPUB), with a low/high detail flag, plus a free TTS cue that signals to the user when the spoken paragraph sits next to a figure or equation.

**Architecture:** One shared DOM heuristic (`visualHeuristic`) feeds two consumers. The voice-chat side adds an `inspectCurrentPage` tool to `buildRealtimeAgent` that calls a new `pageCapture` utility (dispatches PDF canvas vs. EPUB iframe via `html-to-image`). The TTS side emits a `visual-nearby` event on paragraph advance that a small UI affordance renders. Tool-call-only — no eager image transmission.

**Tech Stack:** TypeScript, React, Zustand, `@openai/agents@^0.3.9`, `react-pdf@^10`, `epubjs@^0.3`, `html-to-image` (new dep), `vitest@^4`, `zod`, `effect`.

**Spec:** `docs/superpowers/specs/2026-05-20-voice-chat-page-vision-design.md`

---

## File Structure

**Create:**
- `apps/rishi-electron/src/renderer/src/lib/visualHeuristic.ts` — shared DOM/text detection of equations, figures, images.
- `apps/rishi-electron/src/renderer/src/lib/visualHeuristic.test.ts`
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/index.ts` — top-level `captureCurrentPage` + `summarizeCurrentPage`.
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/index.test.ts`
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/pdfCanvasRegistry.ts` — weak ref to latest rendered PDF canvas.
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/pdfCanvasRegistry.test.ts`
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/epubFrameRegistry.ts` — weak ref to active EPUB iframe.
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/epubFrameRegistry.test.ts`
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.ts` — downscale + WebP encode.
- `apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.test.ts`
- `apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.ts` — emits `visual-nearby` events on paragraph advance.
- `apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.test.ts`
- `apps/rishi-electron/src/renderer/src/components/reader/TTSVisualCue.tsx` — paragraph-anchored affordance UI.
- `apps/rishi-electron/src/renderer/src/components/reader/__tests__/TTSVisualCue.test.tsx`

**Modify:**
- `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts` — register the inspect tool, render visualSummary into instructions.
- `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts`
- `apps/rishi-electron/src/renderer/src/stores/chatStore.ts` — compute `visualSummary` at chat-start and pass through.
- `apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts`
- `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts` — extend `VoiceChatContext` with `visualSummary`.
- `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts` — pipe visualSummary through; on tool capture, send a multimodal conversation item.
- `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts`
- `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.tsx` — register canvas in `pdfCanvasRegistry`.
- `apps/rishi-electron/src/renderer/src/components/react-reader/epub_viewer/index.tsx` (and `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx`) — register iframe.
- `apps/rishi-electron/package.json` — add `html-to-image`.

---

## Task 1: Visual Heuristic Module

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/lib/visualHeuristic.ts`
- Test: `apps/rishi-electron/src/renderer/src/lib/visualHeuristic.test.ts`

- [ ] **Step 1: Write the failing tests**

`apps/rishi-electron/src/renderer/src/lib/visualHeuristic.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { detectVisualsNear, summarizeVisuals } from './visualHeuristic'

function dom(html: string): HTMLBodyElement {
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, 'text/html')
  return doc.body as HTMLBodyElement
}

describe('detectVisualsNear', () => {
  it('returns empty for a paragraph with no nearby visuals', () => {
    const body = dom(`<p id="p1">Just text.</p><p id="p2">More text.</p>`)
    const anchor = body.querySelector('#p1')!
    expect(detectVisualsNear(anchor)).toEqual([])
  })

  it('detects a sibling figure', () => {
    const body = dom(`<p id="p1">Text.</p><figure><img src="x" alt="diagram"/></figure>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    expect(hits).toHaveLength(1)
    expect(hits[0].kind).toBe('figure')
  })

  it('detects inline math element in the paragraph itself', () => {
    const body = dom(`<p id="p1">Text <math><mi>x</mi></math> more.</p>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    expect(hits.some((h) => h.kind === 'equation')).toBe(true)
  })

  it('detects LaTeX inline-dollar with math characters', () => {
    const body = dom(`<p id="p1">When $x = y + 1$ holds, ...</p>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    expect(hits.some((h) => h.kind === 'equation')).toBe(true)
  })

  it('does NOT trigger on $100 (no math characters)', () => {
    const body = dom(`<p id="p1">It costs $100 today.</p>`)
    expect(detectVisualsNear(body.querySelector('#p1')!)).toEqual([])
  })

  it('detects display math with double-dollar', () => {
    const body = dom(`<p id="p1">Then $$ \\int_0^1 x^2 dx $$ follows.</p>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    expect(hits.some((h) => h.kind === 'equation')).toBe(true)
  })

  it('detects katex/mathjax spans by class', () => {
    const body = dom(`<p id="p1">Eq: <span class="katex">y=mx+b</span></p>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    expect(hits.some((h) => h.kind === 'equation')).toBe(true)
  })

  it('respects siblingRadius=0 (anchor only)', () => {
    const body = dom(`<p id="p1">Text.</p><figure><img src="x"/></figure>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!, { siblingRadius: 0 })
    expect(hits).toEqual([])
  })

  it('classifies an img tagged "equation" as equation, not figure', () => {
    const body = dom(`<p id="p1">x</p><img class="equation-image" src="x" alt="eq"/>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    expect(hits[0].kind).toBe('equation')
  })

  it('treats large img (>32px) as figure, ignores tiny tracker pixels', () => {
    const body = dom(
      `<p id="p1">x</p>` +
        `<img src="tracker" width="1" height="1"/>` +
        `<img src="diagram" width="400" height="300"/>`
    )
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    expect(hits).toHaveLength(1)
    expect(hits[0].kind).toBe('figure')
  })
})

describe('summarizeVisuals', () => {
  it('counts equations, figures, images across the root', () => {
    const body = dom(
      `<p>$ x = 1 $</p>` +
        `<figure><img src="f" width="100" height="100"/></figure>` +
        `<img src="g" width="100" height="100"/>` +
        `<math><mi>y</mi></math>`
    )
    expect(summarizeVisuals(body)).toEqual({ equations: 2, figures: 1, images: 1 })
  })

  it('returns zeros for a plain text root', () => {
    const body = dom(`<p>Nothing visual here.</p>`)
    expect(summarizeVisuals(body)).toEqual({ equations: 0, figures: 0, images: 0 })
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/lib/visualHeuristic.test.ts`
Expected: FAIL with "Cannot find module './visualHeuristic'"

- [ ] **Step 3: Implement `visualHeuristic.ts`**

```ts
// apps/rishi-electron/src/renderer/src/lib/visualHeuristic.ts

export type VisualKind = 'equation' | 'figure' | 'image'

export interface VisualHit {
  kind: VisualKind
  element: Element | null
  label: string
}

export interface DetectionOptions {
  /** How many sibling steps before/after the anchor to scan. Default 1. */
  siblingRadius?: number
}

export interface VisualSummary {
  equations: number
  figures: number
  images: number
}

const LATEX_DELIMS = [
  /\$\$([\s\S]+?)\$\$/g,
  /\$([^\n$]+?)\$/g,
  /\\\(([\s\S]+?)\\\)/g,
  /\\\[([\s\S]+?)\\\]/g
]
const MATH_CHARS = /[=+\-^_\\]|\\frac|\\sum|\\int|\\sqrt|\\alpha|\\beta|\\pi/

const EQUATION_CLASS_RE = /\b(equation|formula|math|katex|mathjax)\b/i
const EQUATION_ALT_RE = /equation|formula|math/i

function hasLatexEquation(text: string): boolean {
  for (const re of LATEX_DELIMS) {
    re.lastIndex = 0
    let m: RegExpExecArray | null
    while ((m = re.exec(text)) !== null) {
      if (MATH_CHARS.test(m[1])) return true
    }
  }
  return false
}

function classifyElement(el: Element): VisualHit | null {
  const tag = el.tagName.toLowerCase()

  if (tag === 'math') {
    return { kind: 'equation', element: el, label: 'equation' }
  }

  if (tag === 'figure') {
    return { kind: 'figure', element: el, label: 'figure' }
  }

  if (tag === 'img') {
    const alt = el.getAttribute('alt') ?? ''
    const cls = el.getAttribute('class') ?? ''
    if (EQUATION_CLASS_RE.test(cls) || EQUATION_ALT_RE.test(alt)) {
      return { kind: 'equation', element: el, label: 'equation image' }
    }
    const width = Number(el.getAttribute('width') ?? '0')
    const height = Number(el.getAttribute('height') ?? '0')
    if (width > 32 && height > 32) {
      return { kind: 'figure', element: el, label: 'figure' }
    }
    return null
  }

  if (tag === 'svg') {
    const width = Number(el.getAttribute('width') ?? '0')
    const height = Number(el.getAttribute('height') ?? '0')
    if (width > 32 && height > 32) {
      return { kind: 'figure', element: el, label: 'figure' }
    }
    return null
  }

  if ((tag === 'span' || tag === 'div') && EQUATION_CLASS_RE.test(el.className)) {
    return { kind: 'equation', element: el, label: 'equation' }
  }

  return null
}

function scanElement(el: Element, hits: VisualHit[]): void {
  const direct = classifyElement(el)
  if (direct) hits.push(direct)

  if (hasLatexEquation(el.textContent ?? '')) {
    hits.push({ kind: 'equation', element: el, label: 'equation' })
  }

  for (const child of Array.from(el.children)) {
    const inner = classifyElement(child)
    if (inner) hits.push(inner)
  }
}

export function detectVisualsNear(anchor: Node, opts: DetectionOptions = {}): VisualHit[] {
  const radius = opts.siblingRadius ?? 1
  const hits: VisualHit[] = []

  if (anchor.nodeType !== Node.ELEMENT_NODE) return hits
  const el = anchor as Element

  scanElement(el, hits)

  let prev: Element | null = el.previousElementSibling
  for (let i = 0; i < radius && prev; i++) {
    scanElement(prev, hits)
    prev = prev.previousElementSibling
  }

  let next: Element | null = el.nextElementSibling
  for (let i = 0; i < radius && next; i++) {
    scanElement(next, hits)
    next = next.nextElementSibling
  }

  return hits
}

export function summarizeVisuals(root: Element): VisualSummary {
  let equations = 0
  let figures = 0
  let images = 0

  const walker = root.ownerDocument!.createTreeWalker(root, NodeFilter.SHOW_ELEMENT)
  let node = walker.currentNode as Element | null
  while (node) {
    const hit = classifyElement(node)
    if (hit) {
      if (hit.kind === 'equation') equations++
      else if (hit.kind === 'figure') figures++
      else if (hit.kind === 'image') images++
    }
    node = walker.nextNode() as Element | null
  }

  for (const re of LATEX_DELIMS) {
    re.lastIndex = 0
    let m: RegExpExecArray | null
    const text = root.textContent ?? ''
    while ((m = re.exec(text)) !== null) {
      if (MATH_CHARS.test(m[1])) equations++
    }
  }

  return { equations, figures, images }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/lib/visualHeuristic.test.ts`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/lib/visualHeuristic.ts apps/rishi-electron/src/renderer/src/lib/visualHeuristic.test.ts
git commit -m "feat(electron): add visualHeuristic for equation/figure detection"
```

---

## Task 2: Encode Utility — Downscale + WebP

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.ts`
- Test: `apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.test.ts`

- [ ] **Step 1: Write the failing tests**

```ts
// encode.test.ts
import { describe, it, expect } from 'vitest'
import { encodeCanvasToWebp, downscaleTarget } from './encode'

describe('downscaleTarget', () => {
  it('returns source size when smaller than max', () => {
    expect(downscaleTarget(800, 600, 1024)).toEqual({ width: 800, height: 600 })
  })

  it('scales width to max and keeps aspect ratio', () => {
    expect(downscaleTarget(2000, 1500, 1024)).toEqual({ width: 1024, height: 768 })
  })

  it('does not upscale', () => {
    expect(downscaleTarget(500, 400, 2048)).toEqual({ width: 500, height: 400 })
  })
})

describe('encodeCanvasToWebp', () => {
  it('returns a webp data URL whose length is non-trivial', async () => {
    const canvas = document.createElement('canvas')
    canvas.width = 200
    canvas.height = 100
    const ctx = canvas.getContext('2d')!
    ctx.fillStyle = '#f00'
    ctx.fillRect(0, 0, 200, 100)

    const result = await encodeCanvasToWebp(canvas, { maxWidth: 1024, quality: 0.75 })

    expect(result.dataUrl.startsWith('data:image/webp;base64,')).toBe(true)
    expect(result.width).toBe(200)
    expect(result.height).toBe(100)
    expect(result.bytes).toBeGreaterThan(50)
  })

  it('downscales when source exceeds maxWidth', async () => {
    const canvas = document.createElement('canvas')
    canvas.width = 2000
    canvas.height = 1000
    const result = await encodeCanvasToWebp(canvas, { maxWidth: 1024, quality: 0.75 })
    expect(result.width).toBe(1024)
    expect(result.height).toBe(512)
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/encode.test.ts`
Expected: FAIL with "Cannot find module './encode'"

- [ ] **Step 3: Implement `encode.ts`**

```ts
// apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.ts

export interface EncodeOptions {
  maxWidth: number
  quality: number
}

export interface EncodeResult {
  dataUrl: string
  width: number
  height: number
  bytes: number
}

export function downscaleTarget(
  srcW: number,
  srcH: number,
  maxWidth: number
): { width: number; height: number } {
  if (srcW <= maxWidth) return { width: srcW, height: srcH }
  const scale = maxWidth / srcW
  return { width: maxWidth, height: Math.round(srcH * scale) }
}

export async function encodeCanvasToWebp(
  source: HTMLCanvasElement,
  opts: EncodeOptions
): Promise<EncodeResult> {
  const { width, height } = downscaleTarget(source.width, source.height, opts.maxWidth)

  let target: HTMLCanvasElement
  if (width === source.width && height === source.height) {
    target = source
  } else {
    target = document.createElement('canvas')
    target.width = width
    target.height = height
    const ctx = target.getContext('2d')
    if (!ctx) throw new Error('encodeCanvasToWebp: 2D context unavailable')
    ctx.imageSmoothingQuality = 'high'
    ctx.drawImage(source, 0, 0, width, height)
  }

  const blob: Blob = await new Promise((resolve, reject) =>
    target.toBlob(
      (b) => (b ? resolve(b) : reject(new Error('toBlob returned null'))),
      'image/webp',
      opts.quality
    )
  )

  const dataUrl = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () => reject(reader.error)
    reader.onload = () => resolve(String(reader.result))
    reader.readAsDataURL(blob)
  })

  return { dataUrl, width, height, bytes: blob.size }
}
```

- [ ] **Step 4: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/encode.test.ts`
Expected: all tests PASS. (Note: vitest's jsdom environment must provide `HTMLCanvasElement.prototype.toBlob`. If the run fails with "toBlob is not a function", install `vitest-canvas-mock` and import it at the top of the test file.)

- [ ] **Step 5: If `toBlob` is unavailable in the test env**

Run:
```bash
pnpm --filter rishi-electron add -D vitest-canvas-mock
```

Add to the top of `encode.test.ts`:
```ts
import 'vitest-canvas-mock'
```

Re-run step 4.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.ts apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.test.ts apps/rishi-electron/package.json apps/rishi-electron/pnpm-lock.yaml
git commit -m "feat(electron): add canvas to webp encode helper with downscaling"
```

---

## Task 3: PDF Canvas Registry

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/modules/pageCapture/pdfCanvasRegistry.ts`
- Test: `apps/rishi-electron/src/renderer/src/modules/pageCapture/pdfCanvasRegistry.test.ts`

- [ ] **Step 1: Write the failing tests**

```ts
// pdfCanvasRegistry.test.ts
import { describe, it, expect, beforeEach } from 'vitest'
import {
  registerPdfCanvas,
  unregisterPdfCanvas,
  getActivePdfCanvas,
  __resetPdfCanvasRegistryForTest
} from './pdfCanvasRegistry'

describe('pdfCanvasRegistry', () => {
  beforeEach(() => __resetPdfCanvasRegistryForTest())

  it('returns null when nothing registered', () => {
    expect(getActivePdfCanvas()).toBeNull()
  })

  it('returns the most recently registered canvas', () => {
    const a = document.createElement('canvas')
    const b = document.createElement('canvas')
    registerPdfCanvas(1, a)
    registerPdfCanvas(2, b)
    expect(getActivePdfCanvas()).toBe(b)
  })

  it('falls back to a previous page after unregister', () => {
    const a = document.createElement('canvas')
    const b = document.createElement('canvas')
    registerPdfCanvas(1, a)
    registerPdfCanvas(2, b)
    unregisterPdfCanvas(2)
    expect(getActivePdfCanvas()).toBe(a)
  })

  it('returns null after all pages unregistered', () => {
    const a = document.createElement('canvas')
    registerPdfCanvas(1, a)
    unregisterPdfCanvas(1)
    expect(getActivePdfCanvas()).toBeNull()
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/pdfCanvasRegistry.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `pdfCanvasRegistry.ts`**

```ts
// apps/rishi-electron/src/renderer/src/modules/pageCapture/pdfCanvasRegistry.ts

/**
 * Tracks the canvases that react-pdf has finished rendering for the currently
 * mounted document. The "active" canvas is the most recently registered one.
 */
const canvases = new Map<number, HTMLCanvasElement>()
let registrationOrder: number[] = []

export function registerPdfCanvas(pageNumber: number, canvas: HTMLCanvasElement): void {
  canvases.set(pageNumber, canvas)
  registrationOrder = registrationOrder.filter((n) => n !== pageNumber)
  registrationOrder.push(pageNumber)
}

export function unregisterPdfCanvas(pageNumber: number): void {
  canvases.delete(pageNumber)
  registrationOrder = registrationOrder.filter((n) => n !== pageNumber)
}

export function getActivePdfCanvas(): HTMLCanvasElement | null {
  for (let i = registrationOrder.length - 1; i >= 0; i--) {
    const cv = canvases.get(registrationOrder[i])
    if (cv) return cv
  }
  return null
}

/** Test-only reset. */
export function __resetPdfCanvasRegistryForTest(): void {
  canvases.clear()
  registrationOrder = []
}
```

- [ ] **Step 4: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/pdfCanvasRegistry.test.ts`
Expected: all PASS.

- [ ] **Step 5: Wire `pdf-page.tsx` to register/unregister**

Read `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.tsx` first (already confirmed: `handleRenderSuccess` is at line 113 and `onRenderSuccess` is wired at line 163).

Modify `pdf-page.tsx`:

1. Add import near the other imports:
   ```ts
   import { registerPdfCanvas, unregisterPdfCanvas } from '@/modules/pageCapture/pdfCanvasRegistry'
   ```
2. Add a `pageRef`:
   ```ts
   const pageRef = useRef<HTMLDivElement | null>(null)
   ```
   Wrap the existing `<Page ... />` JSX in `<div ref={pageRef}>...</div>` if it isn't already.
3. Update `handleRenderSuccess` to grab the canvas:
   ```ts
   const handleRenderSuccess = useCallback(() => {
     const canvas = pageRef.current?.querySelector('canvas')
     if (canvas instanceof HTMLCanvasElement) {
       registerPdfCanvas(pageNumber, canvas)
     }
     // ...keep the existing body of handleRenderSuccess
   }, [pageNumber])
   ```
4. Add cleanup on unmount:
   ```ts
   useEffect(() => () => unregisterPdfCanvas(pageNumber), [pageNumber])
   ```

- [ ] **Step 6: Manual smoke test**

Run the renderer:
```bash
pnpm --filter rishi-electron dev
```
Open any PDF. In `pdf-page.tsx` temporarily add a `console.log('[pdfCanvasRegistry] registered', pageNumber, canvas)` inside `handleRenderSuccess` after the registration call. Confirm in DevTools that registration fires per page with a non-null canvas. Remove the log before committing.

- [ ] **Step 7: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/modules/pageCapture/pdfCanvasRegistry.ts apps/rishi-electron/src/renderer/src/modules/pageCapture/pdfCanvasRegistry.test.ts apps/rishi-electron/src/renderer/src/components/pdf/components/pdf-page.tsx
git commit -m "feat(electron): expose PDF canvas to pageCapture via registry"
```

---

## Task 4: EPUB Frame Registry

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/modules/pageCapture/epubFrameRegistry.ts`
- Test: `apps/rishi-electron/src/renderer/src/modules/pageCapture/epubFrameRegistry.test.ts`

- [ ] **Step 1: Write the failing tests**

```ts
// epubFrameRegistry.test.ts
import { describe, it, expect, beforeEach } from 'vitest'
import { registerEpubFrame, clearEpubFrame, getActiveEpubFrame } from './epubFrameRegistry'

describe('epubFrameRegistry', () => {
  beforeEach(() => clearEpubFrame())

  it('returns null when nothing registered', () => {
    expect(getActiveEpubFrame()).toBeNull()
  })

  it('returns the registered iframe', () => {
    const f = document.createElement('iframe')
    registerEpubFrame(f)
    expect(getActiveEpubFrame()).toBe(f)
  })

  it('replaces previous registration', () => {
    const a = document.createElement('iframe')
    const b = document.createElement('iframe')
    registerEpubFrame(a)
    registerEpubFrame(b)
    expect(getActiveEpubFrame()).toBe(b)
  })

  it('clears on demand', () => {
    registerEpubFrame(document.createElement('iframe'))
    clearEpubFrame()
    expect(getActiveEpubFrame()).toBeNull()
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/epubFrameRegistry.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `epubFrameRegistry.ts`**

```ts
// apps/rishi-electron/src/renderer/src/modules/pageCapture/epubFrameRegistry.ts

let activeFrame: HTMLIFrameElement | null = null

export function registerEpubFrame(frame: HTMLIFrameElement): void {
  activeFrame = frame
}

export function clearEpubFrame(): void {
  activeFrame = null
}

export function getActiveEpubFrame(): HTMLIFrameElement | null {
  return activeFrame
}
```

- [ ] **Step 4: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/epubFrameRegistry.test.ts`
Expected: all PASS.

- [ ] **Step 5: Wire EPUB viewer to register the rendition iframe**

Read `apps/rishi-electron/src/renderer/src/components/react-reader/epub_viewer/index.tsx` first to find where the epubjs rendition is created and rendered. The rendition exposes views via `rendition.manager.views.first()` (epubjs API), and the view exposes its `iframe` property.

Inside the rendition's `rendered`/`displayed` handler:

```ts
import { registerEpubFrame, clearEpubFrame } from '@/modules/pageCapture/epubFrameRegistry'

// Inside the existing rendered/displayed handler:
rendition.on('rendered', () => {
  const view = rendition.manager?.views?.first?.()
  const iframe = view?.iframe as HTMLIFrameElement | undefined
  if (iframe) registerEpubFrame(iframe)
})

// On unmount:
useEffect(() => () => clearEpubFrame(), [])
```

Apply the same pattern to `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx`.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/modules/pageCapture/epubFrameRegistry.ts apps/rishi-electron/src/renderer/src/modules/pageCapture/epubFrameRegistry.test.ts apps/rishi-electron/src/renderer/src/components/react-reader/epub_viewer/index.tsx apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx
git commit -m "feat(electron): expose EPUB iframe to pageCapture via registry"
```

---

## Task 5: pageCapture Dispatcher

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/modules/pageCapture/index.ts`
- Test: `apps/rishi-electron/src/renderer/src/modules/pageCapture/index.test.ts`

- [ ] **Step 1: Add `html-to-image` dependency**

```bash
pnpm --filter rishi-electron add html-to-image
```

- [ ] **Step 2: Write the failing tests**

```ts
// index.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

const toCanvasMock = vi.fn()
vi.mock('html-to-image', () => ({ toCanvas: toCanvasMock }))

import { captureCurrentPage, summarizeCurrentPage, CaptureError, PageCaptureError } from './index'
import { registerPdfCanvas, __resetPdfCanvasRegistryForTest } from './pdfCanvasRegistry'
import { registerEpubFrame, clearEpubFrame } from './epubFrameRegistry'

function makeCanvas(w: number, h: number, color = '#000'): HTMLCanvasElement {
  const cv = document.createElement('canvas')
  cv.width = w
  cv.height = h
  const ctx = cv.getContext('2d')!
  ctx.fillStyle = color
  ctx.fillRect(0, 0, w, h)
  return cv
}

beforeEach(() => {
  __resetPdfCanvasRegistryForTest()
  clearEpubFrame()
  toCanvasMock.mockReset()
})

describe('captureCurrentPage', () => {
  it('captures the active PDF canvas at low detail (max 1024w)', async () => {
    registerPdfCanvas(1, makeCanvas(2000, 1500, '#abc'))
    const res = await captureCurrentPage({ detail: 'low' })
    expect(res.width).toBe(1024)
    expect(res.dataUrl.startsWith('data:image/webp;base64,')).toBe(true)
  })

  it('captures the active PDF canvas at high detail (max 2048w)', async () => {
    registerPdfCanvas(1, makeCanvas(4000, 3000))
    const res = await captureCurrentPage({ detail: 'high' })
    expect(res.width).toBe(2048)
  })

  it('captures via html-to-image when only an EPUB frame is registered', async () => {
    const iframe = document.createElement('iframe')
    document.body.appendChild(iframe)
    iframe.srcdoc = '<body><p>hello</p></body>'
    await new Promise((r) => setTimeout(r, 10))
    registerEpubFrame(iframe)
    toCanvasMock.mockResolvedValue(makeCanvas(1600, 1200))

    const res = await captureCurrentPage({ detail: 'low' })
    expect(toCanvasMock).toHaveBeenCalledOnce()
    expect(res.width).toBe(1024)
  })

  it('rejects with NotReady when nothing registered', async () => {
    await expect(captureCurrentPage({ detail: 'low' })).rejects.toMatchObject({
      code: CaptureError.NotReady
    })
  })
})

describe('summarizeCurrentPage', () => {
  it('uses the EPUB iframe body when present', () => {
    const iframe = document.createElement('iframe')
    document.body.appendChild(iframe)
    iframe.contentDocument!.open()
    iframe.contentDocument!.write(
      '<body><figure><img width="200" height="200" src="x"/></figure></body>'
    )
    iframe.contentDocument!.close()
    registerEpubFrame(iframe)
    expect(summarizeCurrentPage()).toMatchObject({ figures: 1 })
  })

  it('returns zeros when nothing registered', () => {
    expect(summarizeCurrentPage()).toEqual({ equations: 0, figures: 0, images: 0 })
  })
})
```

- [ ] **Step 3: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/index.test.ts`
Expected: FAIL.

- [ ] **Step 4: Implement `index.ts`**

```ts
// apps/rishi-electron/src/renderer/src/modules/pageCapture/index.ts

import { toCanvas } from 'html-to-image'
import { getActivePdfCanvas } from './pdfCanvasRegistry'
import { getActiveEpubFrame } from './epubFrameRegistry'
import { encodeCanvasToWebp, type EncodeResult } from './encode'
import { summarizeVisuals, type VisualSummary } from '@/lib/visualHeuristic'

export const CaptureError = {
  NotReady: 'NOT_READY',
  Failed: 'FAILED'
} as const
export type CaptureErrorCode = (typeof CaptureError)[keyof typeof CaptureError]

export class PageCaptureError extends Error {
  constructor(public code: CaptureErrorCode, message: string) {
    super(message)
    this.name = 'PageCaptureError'
  }
}

export interface CaptureOptions {
  detail: 'low' | 'high'
}

export type CaptureResult = EncodeResult

const MAX_WIDTH = { low: 1024, high: 2048 } as const
const QUALITY = 0.75

export async function captureCurrentPage(opts: CaptureOptions): Promise<CaptureResult> {
  const maxWidth = MAX_WIDTH[opts.detail]

  const pdfCanvas = getActivePdfCanvas()
  if (pdfCanvas) {
    return encodeCanvasToWebp(pdfCanvas, { maxWidth, quality: QUALITY })
  }

  const frame = getActiveEpubFrame()
  if (frame) {
    const body = frame.contentDocument?.body
    if (!body) {
      throw new PageCaptureError(CaptureError.NotReady, 'EPUB iframe body unavailable')
    }
    let canvas: HTMLCanvasElement
    try {
      canvas = await toCanvas(body, { cacheBust: true, pixelRatio: 1 })
    } catch (err) {
      throw new PageCaptureError(
        CaptureError.Failed,
        `html-to-image failed: ${(err as Error).message}`
      )
    }
    return encodeCanvasToWebp(canvas, { maxWidth, quality: QUALITY })
  }

  throw new PageCaptureError(CaptureError.NotReady, 'No PDF canvas or EPUB iframe registered')
}

export function summarizeCurrentPage(): VisualSummary {
  const pdfCanvas = getActivePdfCanvas()
  if (pdfCanvas) {
    const textLayer = pdfCanvas.parentElement?.querySelector('.react-pdf__Page__textContent')
    if (textLayer) return summarizeVisuals(textLayer)
    return { equations: 0, figures: 0, images: 0 }
  }
  const frame = getActiveEpubFrame()
  if (frame?.contentDocument?.body) {
    return summarizeVisuals(frame.contentDocument.body)
  }
  return { equations: 0, figures: 0, images: 0 }
}
```

- [ ] **Step 5: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/pageCapture/index.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/modules/pageCapture/index.ts apps/rishi-electron/src/renderer/src/modules/pageCapture/index.test.ts apps/rishi-electron/package.json apps/rishi-electron/pnpm-lock.yaml
git commit -m "feat(electron): pageCapture dispatcher for PDF and EPUB"
```

---

## Task 6: Extend `VoiceChatContext` with `visualSummary`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts`

- [ ] **Step 1: Read the current types**

Read `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts` and find `VoiceChatContext` (the shape passed to `service.activate(bookId, ctx)`).

- [ ] **Step 2: Add the optional field**

```ts
import type { VisualSummary } from '@/lib/visualHeuristic'

export interface VoiceChatContext {
  pageText: string
  outline?: BookOutline
  activeParagraphText?: string
  /** Counts of visual content currently on the user's page. */
  visualSummary?: VisualSummary
}
```

- [ ] **Step 3: Verify the type compiles**

```bash
pnpm --filter rishi-electron tsc --noEmit
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts
git commit -m "feat(electron): add visualSummary to VoiceChatContext"
```

---

## Task 7: Render `visualSummary` into Agent Instructions

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`
- Modify: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `buildRealtimeAgent.test.ts`:

```ts
describe('visualSummary rendering', () => {
  it('renders a Visual context section when summary has content', () => {
    const agent = buildRealtimeAgent({
      bookId: 1,
      pageText: 'hello',
      onEndConversation: () => {},
      language: 'en',
      visualSummary: { equations: 1, figures: 2, images: 0 }
    })
    expect(agent.instructions).toContain('## Visual context')
    expect(agent.instructions).toContain('1 equation')
    expect(agent.instructions).toContain('2 figures')
    expect(agent.instructions).toContain('inspectCurrentPage')
  })

  it('renders "no visual content" when summary is all zeros', () => {
    const agent = buildRealtimeAgent({
      bookId: 1,
      pageText: 'hello',
      onEndConversation: () => {},
      language: 'en',
      visualSummary: { equations: 0, figures: 0, images: 0 }
    })
    expect(agent.instructions).toContain('no visual content')
  })

  it('omits the section entirely when visualSummary is undefined', () => {
    const agent = buildRealtimeAgent({
      bookId: 1,
      pageText: 'hello',
      onEndConversation: () => {},
      language: 'en'
    })
    expect(agent.instructions).not.toContain('## Visual context')
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: FAIL.

- [ ] **Step 3: Modify `buildRealtimeAgent.ts`**

Add to imports:
```ts
import type { VisualSummary } from '@/lib/visualHeuristic'
```

Extend `BuildAgentOptions`:
```ts
visualSummary?: VisualSummary
```

Add a renderer function above `INSTRUCTIONS_TEMPLATE`:
```ts
function renderVisualSection(summary: VisualSummary | undefined): string {
  if (!summary) return ''
  const parts: string[] = []
  if (summary.equations > 0)
    parts.push(`${summary.equations} ${summary.equations === 1 ? 'equation' : 'equations'}`)
  if (summary.figures > 0)
    parts.push(`${summary.figures} ${summary.figures === 1 ? 'figure' : 'figures'}`)
  if (summary.images > 0)
    parts.push(`${summary.images} ${summary.images === 1 ? 'image' : 'images'}`)
  const description = parts.length > 0 ? parts.join(' and ') : 'no visual content (text-only page)'

  return `## Visual context
The current page contains ${description}.

You have a tool \`inspectCurrentPage({ detail: 'low' | 'high' })\` that returns a screenshot of what the user is looking at right now. Use \`detail: 'low'\` (default) for general layout questions. Use \`detail: 'high'\` only if you need to read small text inside the image (equations, captions, axis labels). Do not call it on every turn — only when the user's question requires visual context.

`
}
```

Update `INSTRUCTIONS_TEMPLATE` to accept and render `visualSummary`:
```ts
const INSTRUCTIONS_TEMPLATE = (
  pageText: string,
  language: string,
  outline?: BookOutline,
  activeParagraphText?: string,
  visualSummary?: VisualSummary
) => `## Role
You are a teaching assistant helping the user understand the book they're reading.

${renderLanguageSection(language)}${renderOutlineSection(outline)}${renderVisualSection(visualSummary)}## Current Page Content
"""
${pageText || '(No page text available)'}
"""
If the question is answerable from this page, answer directly. Use the bookContext tool only for content outside this page.

${renderActiveParagraphSection(activeParagraphText)}

## Rules
- Vary phrasing — never repeat the same sentence verbatim in a single response.
- Stay conversational; avoid scripted-sounding language.
- Before calling a tool, say one short line previewing what you're doing (5-12 words).
- Stay focused on the book, but allow natural chat flow.

## Tools

### bookContext
For content NOT visible on the current page. Provide a brief preamble before calling.

### endConversation
When the user clearly signals they're done, respond with a warm closing and call this tool. If ambiguous, confirm first. Provide a clear \`reason\`.

## Style notes
- First message: if the user asks a question, answer it directly. If they greet, respond briefly and ask how you can help.
- When explaining concepts, break down complexity and use analogies. Briefly check understanding before moving on.
- Keep responses concise unless depth is requested.`
```

In `buildRealtimeAgent`, destructure `visualSummary` and pass it to the template:
```ts
export function buildRealtimeAgent({
  bookId, pageText, outline, activeParagraphText, onEndConversation, language, rag,
  visualSummary
}: BuildAgentOptions): RealtimeAgent {
  // ...existing tool definitions stay
  return new RealtimeAgent({
    name: 'Assistant',
    voice: 'alloy',
    instructions: INSTRUCTIONS_TEMPLATE(pageText, language, outline, activeParagraphText, visualSummary),
    tools: [bookContextTool, endConversationTool]
  })
}
```

- [ ] **Step 4: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: all PASS, including pre-existing tests.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts
git commit -m "feat(electron): render visualSummary into realtime agent instructions"
```

---

## Task 8: Add `inspectCurrentPage` Tool

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`
- Modify: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts`

> **SDK note:** `@openai/agents@^0.3.9` tools return a string from their executor. To deliver an image as a tool result in the realtime API, the tool returns a short text marker (e.g. "Image attached.") while pushing the image into the conversation via the session transport. We do not have a session handle inside `buildRealtimeAgent`, so the tool captures the image and invokes an `onInspectImage` callback that the service layer (Task 9) uses to forward the image to the session.

- [ ] **Step 1: Write the failing test**

Append to `buildRealtimeAgent.test.ts`:

```ts
import * as pageCapture from '@/modules/pageCapture'

describe('inspectCurrentPage tool', () => {
  it('is registered on the agent', () => {
    const agent = buildRealtimeAgent({
      bookId: 1,
      pageText: 'x',
      onEndConversation: () => {},
      language: 'en',
      visualSummary: { equations: 0, figures: 1, images: 0 }
    })
    const names = agent.tools.map((t) => (t as { name: string }).name)
    expect(names).toContain('inspectCurrentPage')
  })

  it('executor calls captureCurrentPage with the chosen detail and reports back', async () => {
    const spy = vi.spyOn(pageCapture, 'captureCurrentPage').mockResolvedValue({
      dataUrl: 'data:image/webp;base64,AAA',
      width: 1024,
      height: 768,
      bytes: 100
    })
    const onImage = vi.fn()
    const agent = buildRealtimeAgent({
      bookId: 1,
      pageText: 'x',
      onEndConversation: () => {},
      language: 'en',
      visualSummary: { equations: 0, figures: 1, images: 0 },
      onInspectImage: onImage
    })
    const t = agent.tools.find((x) => (x as { name: string }).name === 'inspectCurrentPage') as {
      execute: (a: { detail: 'low' | 'high' }) => Promise<string>
    }
    const result = await t.execute({ detail: 'high' })
    expect(spy).toHaveBeenCalledWith({ detail: 'high' })
    expect(onImage).toHaveBeenCalledWith({
      dataUrl: 'data:image/webp;base64,AAA',
      width: 1024,
      height: 768,
      bytes: 100
    })
    expect(result).toMatch(/image/i)
  })

  it('returns a graceful text fallback on capture failure', async () => {
    vi.spyOn(pageCapture, 'captureCurrentPage').mockRejectedValue(
      new pageCapture.PageCaptureError(pageCapture.CaptureError.NotReady, 'no canvas')
    )
    const agent = buildRealtimeAgent({
      bookId: 1,
      pageText: 'x',
      onEndConversation: () => {},
      language: 'en',
      visualSummary: { equations: 0, figures: 1, images: 0 }
    })
    const t = agent.tools.find((x) => (x as { name: string }).name === 'inspectCurrentPage') as {
      execute: (a: { detail: 'low' | 'high' }) => Promise<string>
    }
    const result = await t.execute({ detail: 'low' })
    expect(result.toLowerCase()).toContain('unavailable')
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: FAIL.

- [ ] **Step 3: Add the tool to `buildRealtimeAgent.ts`**

Imports:
```ts
import { captureCurrentPage, type CaptureResult } from '@/modules/pageCapture'
```

Extend `BuildAgentOptions`:
```ts
/**
 * Called when the inspect tool successfully captures an image. The caller
 * (service.ts) uses this hook to inject the image into the realtime
 * conversation via the session transport.
 */
onInspectImage?: (image: CaptureResult) => void
```

Inside `buildRealtimeAgent`, after the existing tools:

```ts
const inspectCurrentPageExecute = ({ detail }: { detail: 'low' | 'high' }) =>
  runToolCall<string>(
    'inspectCurrentPage',
    'Page image is currently unavailable; the text context still applies.',
    async () => {
      const image = await captureCurrentPage({ detail })
      onInspectImage?.(image)
      return `Page image captured at ${image.width}x${image.height} (${detail} detail). Attached to the conversation.`
    }
  )

const inspectCurrentPageTool = Object.assign(
  tool({
    name: 'inspectCurrentPage',
    description:
      "Capture a screenshot of the page the user is currently looking at. Use 'low' detail by default; use 'high' only when you need to read small text inside the image such as equations, captions, or axis labels.",
    parameters: z.object({
      detail: z.enum(['low', 'high']).default('low')
    }),
    execute: inspectCurrentPageExecute
  }),
  { execute: inspectCurrentPageExecute }
)
```

Update the tools array on the returned agent — but only include `inspectCurrentPageTool` when `visualSummary` is defined (this is the seam that the settings toggle in Task 14 will gate):

```ts
const tools: unknown[] = [bookContextTool, endConversationTool]
if (visualSummary !== undefined) tools.push(inspectCurrentPageTool)

return new RealtimeAgent({
  name: 'Assistant',
  voice: 'alloy',
  instructions: INSTRUCTIONS_TEMPLATE(pageText, language, outline, activeParagraphText, visualSummary),
  tools: tools as never
})
```

- [ ] **Step 4: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts
git commit -m "feat(electron): add inspectCurrentPage tool to realtime agent"
```

---

## Task 9: Inject Captured Image into Realtime Conversation

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts`

> **Goal:** wire the `onInspectImage` callback from Task 8 into the realtime session so the captured image becomes a real conversation item the model sees on its next turn.
>
> **Mechanism:** add an `input_image` content part to a `conversation.item.create` event on the session transport. The exact accessor on the session object (e.g. `session.transport.sendEvent`) must be confirmed against `@openai/agents@^0.3.9` — see Step 1.

- [ ] **Step 1: Read `service.ts` and confirm the SDK transport API**

Read `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts` to find where the `RealtimeSession` is created and identify the variable that holds it after connection.

Confirm the SDK's session-transport shape with:
```bash
pnpm --filter rishi-electron node -e "const r = require('@openai/agents/realtime'); console.log(Object.keys(r))"
```

If the SDK uses a different method name than `transport.sendEvent` (for example `session.sendRawEvent` or `session.transport.send`), substitute that everywhere this task references it.

- [ ] **Step 2: Write the failing test**

Append to `service.test.ts`. Model the helper after the existing dependency-injection patterns in this test file (mock the session factory the service already accepts).

```ts
describe('inspectCurrentPage image injection', () => {
  it('sends a conversation.item.create event with the captured image', async () => {
    const sendEvent = vi.fn()
    const fakeSession = { transport: { sendEvent } }
    const { capturedOnInspect } = await setupServiceWithStubbedSession(fakeSession)
    capturedOnInspect({
      dataUrl: 'data:image/webp;base64,XYZ',
      width: 800,
      height: 600,
      bytes: 100
    })
    expect(sendEvent).toHaveBeenCalledWith(
      expect.objectContaining({
        type: 'conversation.item.create',
        item: expect.objectContaining({
          type: 'message',
          role: 'user',
          content: [
            expect.objectContaining({
              type: 'input_image',
              image_url: 'data:image/webp;base64,XYZ'
            })
          ]
        })
      })
    )
  })
})
```

The `setupServiceWithStubbedSession(fakeSession)` helper must:
- inject `fakeSession` via the existing session-factory seam in `service.ts`,
- spy on `buildRealtimeAgent` to capture the `onInspectImage` callback the service passes,
- return both the service and the captured callback.

- [ ] **Step 3: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/service.test.ts -t 'inspectCurrentPage image injection'`
Expected: FAIL.

- [ ] **Step 4: Implement in `service.ts`**

In the agent-building path:

```ts
const agent = buildRealtimeAgent({
  bookId,
  pageText,
  outline,
  activeParagraphText,
  language,
  visualSummary,
  onEndConversation,
  rag,
  onInspectImage: (image) => {
    session.transport.sendEvent({
      type: 'conversation.item.create',
      item: {
        type: 'message',
        role: 'user',
        content: [
          {
            type: 'input_image',
            image_url: image.dataUrl
          }
        ]
      }
    })
  }
})
```

If `session.transport.sendEvent` is not the actual SDK accessor (per Step 1), swap it for the correct one.

- [ ] **Step 5: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/service.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "feat(electron): inject captured page image into realtime conversation"
```

---

## Task 10: Pipe `visualSummary` Through `chatStore.startChat`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/stores/chatStore.ts`
- Modify: `apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `chatStore.test.ts`:

```ts
import * as pageCapture from '@/modules/pageCapture'

it('startChat passes visualSummary from pageCapture to voice.activate', () => {
  vi.spyOn(pageCapture, 'summarizeCurrentPage').mockReturnValue({
    equations: 2,
    figures: 1,
    images: 0
  })
  const activateSpy = vi
    .spyOn(getVoiceChatService(), 'activate')
    .mockResolvedValue(undefined as never)

  useChatStore.getState().startChat(42)

  expect(activateSpy).toHaveBeenCalledWith(
    42,
    expect.objectContaining({
      visualSummary: { equations: 2, figures: 1, images: 0 }
    })
  )
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/stores/chatStore.test.ts -t 'visualSummary'`
Expected: FAIL.

- [ ] **Step 3: Modify `chatStore.ts`**

Add import:
```ts
import { summarizeCurrentPage } from '@/modules/pageCapture'
```

In `startChat`, compute and pass the summary:
```ts
startChat: (bookId) => {
  const playerState = usePlayerStore.getState()
  const pageText = playerState.currentParagraphs.map((p) => p.text).join('\n')
  const activeParagraphText = playerState.activeParagraph?.text
  const epubState = useEpubStore.getState()
  const outline =
    epubState.bookId === String(bookId) ? (epubState.bookOutline ?? undefined) : undefined

  const visualSummary = summarizeCurrentPage()

  voice
    .activate(bookId, { pageText, outline, activeParagraphText, visualSummary })
    .catch((err: unknown) => {
      if (!(err instanceof OfflineError)) {
        captureError(err, { operation: 'chatStore', step: 'activate' })
      }
      const send = usePlayerStore.getState().send
      if (send) send({ type: 'CHAT_ENDED' })
      set({ isChatting: false, chatStatus: 'idle' })
    })
}
```

- [ ] **Step 4: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/stores/chatStore.test.ts`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/stores/chatStore.ts apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts
git commit -m "feat(electron): pipe visualSummary into voice chat activation"
```

---

## Task 11: TTS Visual Cue Emitter

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.ts`
- Test: `apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.test.ts`

- [ ] **Step 1: Read existing TTS emitter pattern**

Read `apps/rishi-electron/src/renderer/src/services/tts/emitter.ts` to confirm the local convention for events and subscribe-shape.

- [ ] **Step 2: Write the failing test**

```ts
// visual-cue-emitter.test.ts
import { describe, it, expect, vi } from 'vitest'
import { createVisualCueEmitter } from './visual-cue-emitter'

function paragraphElement(html: string): HTMLElement {
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, 'text/html')
  return doc.body.firstElementChild as HTMLElement
}

describe('visualCueEmitter', () => {
  it('emits hits when the paragraph has a sibling figure', () => {
    const emitter = createVisualCueEmitter()
    const listener = vi.fn()
    emitter.on('visual-nearby', listener)
    const p = paragraphElement(`<div><p id="x">text</p><figure><img width="200" height="200"/></figure></div>`)
    emitter.notifyParagraph({ paragraphId: 'p1', element: p.querySelector('#x')! })
    expect(listener).toHaveBeenCalledWith({
      paragraphId: 'p1',
      hits: expect.arrayContaining([expect.objectContaining({ kind: 'figure' })])
    })
  })

  it('emits with empty hits when no nearby visuals (lets UI clear itself)', () => {
    const emitter = createVisualCueEmitter()
    const listener = vi.fn()
    emitter.on('visual-nearby', listener)
    const p = paragraphElement(`<div><p id="x">text only</p></div>`)
    emitter.notifyParagraph({ paragraphId: 'p1', element: p.querySelector('#x')! })
    expect(listener).toHaveBeenCalledWith({ paragraphId: 'p1', hits: [] })
  })

  it('debounces repeated notifications for the same paragraph', () => {
    const emitter = createVisualCueEmitter()
    const listener = vi.fn()
    emitter.on('visual-nearby', listener)
    const p = paragraphElement(`<div><p id="x">$ x=1 $</p></div>`)
    emitter.notifyParagraph({ paragraphId: 'p1', element: p.querySelector('#x')! })
    emitter.notifyParagraph({ paragraphId: 'p1', element: p.querySelector('#x')! })
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('emits again after paragraph changes', () => {
    const emitter = createVisualCueEmitter()
    const listener = vi.fn()
    emitter.on('visual-nearby', listener)
    const p1 = paragraphElement(`<div><p id="a">$ x=1 $</p></div>`)
    const p2 = paragraphElement(`<div><p id="b">$ y=2 $</p></div>`)
    emitter.notifyParagraph({ paragraphId: 'p1', element: p1.querySelector('#a')! })
    emitter.notifyParagraph({ paragraphId: 'p2', element: p2.querySelector('#b')! })
    expect(listener).toHaveBeenCalledTimes(2)
  })
})
```

- [ ] **Step 3: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/services/tts/visual-cue-emitter.test.ts`
Expected: FAIL.

- [ ] **Step 4: Implement**

```ts
// apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.ts
import { detectVisualsNear, type VisualHit } from '@/lib/visualHeuristic'

export interface VisualNearbyEvent {
  paragraphId: string
  hits: VisualHit[]
}

type Listener = (e: VisualNearbyEvent) => void

export interface VisualCueEmitter {
  on(event: 'visual-nearby', listener: Listener): () => void
  notifyParagraph(input: { paragraphId: string; element: Element }): void
  /** Test-only: synchronously fire to all listeners. */
  __emitForTest?: (event: VisualNearbyEvent) => void
}

export function createVisualCueEmitter(): VisualCueEmitter {
  const listeners = new Set<Listener>()
  let lastParagraphId: string | null = null

  return {
    on(_event, listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    notifyParagraph({ paragraphId, element }) {
      if (paragraphId === lastParagraphId) return
      lastParagraphId = paragraphId
      const hits = detectVisualsNear(element, { siblingRadius: 1 })
      for (const l of listeners) l({ paragraphId, hits })
    },
    __emitForTest(event) {
      for (const l of listeners) l(event)
    }
  }
}
```

- [ ] **Step 5: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/services/tts/visual-cue-emitter.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.ts apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.test.ts
git commit -m "feat(electron): add visual-cue emitter for TTS paragraph advance"
```

---

## Task 12: Wire Emitter into TTS Pipeline

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/stores/playerStore.ts`
- Modify: `apps/rishi-electron/src/renderer/src/stores/playerStore.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/index.ts` (add singleton accessor)

> The exact paragraph-advance call site lives in `playerStore.ts` — confirmed earlier the store has `activeParagraph: ParagraphWithIndex | null`. Read the file to find where `activeParagraph` is assigned and add the notify call immediately after each assignment.

- [ ] **Step 1: Read playerStore to find the paragraph-advance site**

Search for `activeParagraph` assignments:
```
grep -n "activeParagraph" apps/rishi-electron/src/renderer/src/stores/playerStore.ts
```
Pick the call site(s) that run exactly once per paragraph advance.

- [ ] **Step 2: Add a singleton accessor in `services/tts/index.ts`**

Append to `apps/rishi-electron/src/renderer/src/services/tts/index.ts`:

```ts
import { createVisualCueEmitter, type VisualCueEmitter } from './visual-cue-emitter'

let _visualCueEmitter: VisualCueEmitter | null = null
export function getVisualCueEmitter(): VisualCueEmitter {
  if (!_visualCueEmitter) _visualCueEmitter = createVisualCueEmitter()
  return _visualCueEmitter
}
```

Also re-export the type for consumers:
```ts
export type { VisualNearbyEvent } from './visual-cue-emitter'
```

- [ ] **Step 3: Hook the emitter at the paragraph-advance site**

In `playerStore.ts`, immediately after each `activeParagraph` assignment, add:

```ts
import { getVisualCueEmitter } from '@/services/tts'
import { getActiveEpubFrame } from '@/modules/pageCapture/epubFrameRegistry'

// After: set({ activeParagraph: newParagraph })
const id = newParagraph?.id
if (id) {
  const frameBody = getActiveEpubFrame()?.contentDocument?.body
  const element =
    frameBody?.querySelector(`[id="${CSS.escape(id)}"]`) ??
    document.querySelector(`[data-paragraph-id="${id}"]`)
  if (element) {
    getVisualCueEmitter().notifyParagraph({ paragraphId: id, element })
  }
}
```

If `ParagraphWithIndex` uses a different identifier than `id` (e.g. `cfi`, `index`), substitute it everywhere above. The contract is: a stable string identifier per paragraph.

- [ ] **Step 4: Add a regression test**

Append to `playerStore.test.ts`:

```ts
import * as ttsExports from '@/services/tts'

it('notifies the visual cue emitter on paragraph advance', () => {
  const notify = vi.fn()
  vi.spyOn(ttsExports, 'getVisualCueEmitter').mockReturnValue({
    notifyParagraph: notify,
    on: () => () => {}
  } as never)

  const p = document.createElement('p')
  p.id = 'para-1'
  document.body.appendChild(p)

  // Use whatever dispatch pattern the rest of this test file uses to
  // update activeParagraph. The exact call shape is repo-specific.
  setActiveParagraphInStore({ id: 'para-1', text: 'hi', index: 0 })

  expect(notify).toHaveBeenCalledWith({ paragraphId: 'para-1', element: p })
})
```

Where `setActiveParagraphInStore` is shorthand for the existing helper or direct dispatch used in `playerStore.test.ts`. Adapt to the file's existing pattern.

- [ ] **Step 5: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/stores/playerStore.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/tts/index.ts apps/rishi-electron/src/renderer/src/stores/playerStore.ts apps/rishi-electron/src/renderer/src/stores/playerStore.test.ts
git commit -m "feat(electron): emit visual-nearby events on TTS paragraph advance"
```

---

## Task 13: TTS Visual Cue UI Affordance

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/reader/TTSVisualCue.tsx`
- Test: `apps/rishi-electron/src/renderer/src/components/reader/__tests__/TTSVisualCue.test.tsx`
- Modify: a reader root component (confirm via `grep -rln "ReaderOverlayControls" apps/rishi-electron/src/renderer/src`) to mount `<TTSVisualCue />` once.

- [ ] **Step 1: Write the failing test**

```tsx
// TTSVisualCue.test.tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import { TTSVisualCue } from '../TTSVisualCue'
import { getVisualCueEmitter } from '@/services/tts'

describe('TTSVisualCue', () => {
  it('renders nothing by default', () => {
    render(<TTSVisualCue />)
    expect(screen.queryByTestId('tts-visual-cue')).toBeNull()
  })

  it('renders an equation cue when emitter fires an equation hit', () => {
    render(<TTSVisualCue />)
    act(() => {
      getVisualCueEmitter().__emitForTest?.({
        paragraphId: 'p1',
        hits: [{ kind: 'equation', element: null, label: 'equation' }]
      })
    })
    const cue = screen.getByTestId('tts-visual-cue')
    expect(cue).toHaveTextContent(/equation/i)
  })

  it('scrolls the hit element into view when the cue is clicked', () => {
    const el = document.createElement('figure')
    document.body.appendChild(el)
    el.scrollIntoView = vi.fn()
    render(<TTSVisualCue />)
    act(() => {
      getVisualCueEmitter().__emitForTest?.({
        paragraphId: 'p1',
        hits: [{ kind: 'figure', element: el, label: 'figure' }]
      })
    })
    screen.getByTestId('tts-visual-cue').click()
    expect(el.scrollIntoView).toHaveBeenCalled()
  })

  it('clears the cue when a new paragraph has empty hits', () => {
    render(<TTSVisualCue />)
    act(() => {
      getVisualCueEmitter().__emitForTest?.({
        paragraphId: 'p1',
        hits: [{ kind: 'equation', element: null, label: 'equation' }]
      })
    })
    expect(screen.queryByTestId('tts-visual-cue')).not.toBeNull()
    act(() => {
      getVisualCueEmitter().__emitForTest?.({ paragraphId: 'p2', hits: [] })
    })
    expect(screen.queryByTestId('tts-visual-cue')).toBeNull()
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/components/reader/__tests__/TTSVisualCue.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Implement `TTSVisualCue.tsx`**

```tsx
// apps/rishi-electron/src/renderer/src/components/reader/TTSVisualCue.tsx
import { useEffect, useState } from 'react'
import { getVisualCueEmitter, type VisualNearbyEvent } from '@/services/tts'

export function TTSVisualCue(): JSX.Element | null {
  const [event, setEvent] = useState<VisualNearbyEvent | null>(null)

  useEffect(() => {
    const off = getVisualCueEmitter().on('visual-nearby', (e) => {
      setEvent(e.hits.length === 0 ? null : e)
    })
    return off
  }, [])

  if (!event) return null

  const kind = event.hits[0].kind
  const target = event.hits[0].element

  const label =
    kind === 'equation'
      ? 'Equation on page'
      : kind === 'figure'
        ? 'Figure on page'
        : 'Image on page'

  return (
    <button
      type="button"
      data-testid="tts-visual-cue"
      className="fixed bottom-24 right-6 z-50 rounded-full bg-amber-500/90 px-3 py-2 text-sm text-white shadow-lg hover:bg-amber-500"
      onClick={() => {
        target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      }}
    >
      {label}
    </button>
  )
}
```

- [ ] **Step 4: Mount it once in the reader root**

Add `<TTSVisualCue />` to whichever reader overlay component is mounted exactly once per active book (confirm via grep). Likely `apps/rishi-electron/src/renderer/src/components/reader/ReaderOverlayControls.tsx`.

- [ ] **Step 5: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/components/reader/__tests__/TTSVisualCue.test.tsx src/renderer/src/services/tts/visual-cue-emitter.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/reader/TTSVisualCue.tsx apps/rishi-electron/src/renderer/src/components/reader/__tests__/TTSVisualCue.test.tsx apps/rishi-electron/src/renderer/src/components/reader/ReaderOverlayControls.tsx
git commit -m "feat(electron): TTS visual cue affordance with scroll-into-view"
```

---

## Task 14: Settings Toggles

**Files:**
- Modify: settings store (find via `grep -rln "useSettingsStore" apps/rishi-electron/src/renderer/src --include='*.ts' --include='*.tsx'`)
- Modify: settings UI
- Modify: `apps/rishi-electron/src/renderer/src/stores/chatStore.ts` and `apps/rishi-electron/src/renderer/src/components/reader/TTSVisualCue.tsx` to read the toggles.

- [ ] **Step 1: Locate settings infrastructure**

Search:
```
grep -rln "useSettingsStore" apps/rishi-electron/src/renderer/src
```
Read the matched file to learn the existing pattern for adding a new persisted boolean.

- [ ] **Step 2: Add two boolean settings**

In the settings store, add (default `true`):
- `voiceChat.visionEnabled`
- `tts.visualCueEnabled`

Persist them using whatever pattern existing settings use (likely `persist` middleware on the zustand store).

- [ ] **Step 3: Gate behavior**

In `chatStore.ts`, read the toggle and conditionally compute the summary:
```ts
const visionEnabled = useSettingsStore.getState().voiceChat?.visionEnabled ?? true
const visualSummary = visionEnabled ? summarizeCurrentPage() : undefined
```
Pass `visualSummary` (which is now `undefined` when disabled) to `voice.activate`. This single seam disables both the visual-context section in instructions AND tool registration — the conditional `tools.push(inspectCurrentPageTool)` from Task 8 already handles this.

In `TTSVisualCue.tsx`, gate render:
```ts
const enabled = useSettingsStore((s) => s.tts?.visualCueEnabled ?? true)
if (!enabled) return null
```

- [ ] **Step 4: Add tests**

In `buildRealtimeAgent.test.ts`:
```ts
it('does not register inspectCurrentPage when visualSummary is undefined', () => {
  const agent = buildRealtimeAgent({
    bookId: 1,
    pageText: 'x',
    onEndConversation: () => {},
    language: 'en'
  })
  const names = agent.tools.map((t) => (t as { name: string }).name)
  expect(names).not.toContain('inspectCurrentPage')
})
```

In `TTSVisualCue.test.tsx`:
```ts
it('renders nothing when tts.visualCueEnabled is false', () => {
  useSettingsStore.setState({ tts: { visualCueEnabled: false } })
  render(<TTSVisualCue />)
  act(() => {
    getVisualCueEmitter().__emitForTest?.({
      paragraphId: 'p1',
      hits: [{ kind: 'equation', element: null, label: 'equation' }]
    })
  })
  expect(screen.queryByTestId('tts-visual-cue')).toBeNull()
})
```

- [ ] **Step 5: Surface the toggles in settings UI**

Find the existing voice-chat / TTS settings panel via grep and add two switches:
- "Show me what's on the page during voice chat" → `voiceChat.visionEnabled`
- "Highlight figures and equations during read-aloud" → `tts.visualCueEnabled`

- [ ] **Step 6: Run tests**

```bash
pnpm --filter rishi-electron vitest run src/renderer/src/modules/buildRealtimeAgent.test.ts src/renderer/src/components/reader/__tests__/TTSVisualCue.test.tsx src/renderer/src/stores/chatStore.test.ts
```
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/stores/ apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts apps/rishi-electron/src/renderer/src/components/reader/TTSVisualCue.tsx apps/rishi-electron/src/renderer/src/components/reader/__tests__/TTSVisualCue.test.tsx
git commit -m "feat(electron): settings toggles for vision and TTS visual cue"
```

---

## Task 15: Page-Turn Refresh of `visualSummary` During Active Chat

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/stores/playerStore.ts` (or wherever page-change is observable — confirm)

> When the user turns the page while voice chat is active, the visual context the model knows about is now stale. We do NOT send a new image — only the metadata hint. Cheapest path: send a `session.update` event with refreshed instructions OR a `conversation.item.create` with role:`system` carrying just the updated summary line. The latter is less invasive (it doesn't rebuild the full prompt) and is preferred.

- [ ] **Step 1: Confirm page-change observability**

Page changes are reflected in the registries (Tasks 3 and 4) — a new PDF page registers a new canvas, an EPUB section change replaces the frame. The cleanest seam is to have the voice-chat service subscribe to a page-change event from `playerStore`.

Read `apps/rishi-electron/src/renderer/src/stores/playerStore.ts` and identify the field that changes per page advance (likely `currentPageIndex` or similar). Use zustand's `subscribe` API:

```ts
const unsub = usePlayerStore.subscribe(
  (s) => s.currentPageIndex,
  () => emitPageChange()
)
```

If no such field exists, look for `currentParagraphs` reassignment as a proxy. Pick the most stable observable.

- [ ] **Step 2: Write the failing test**

Append to `service.test.ts`:

```ts
import * as pageCapture from '@/modules/pageCapture'

it('sends a refreshed visualSummary message on page change while chat is active', async () => {
  const sendEvent = vi.fn()
  const fakeSession = { transport: { sendEvent } }
  await setupServiceWithStubbedSession(fakeSession)
  vi.spyOn(pageCapture, 'summarizeCurrentPage').mockReturnValue({
    equations: 3,
    figures: 0,
    images: 0
  })

  // Simulate page-change. Use the same pattern other tests in this file use
  // to trigger store updates (e.g. usePlayerStore.setState({ currentPageIndex: 2 })).
  triggerPageChange()

  expect(sendEvent).toHaveBeenCalledWith(
    expect.objectContaining({
      type: 'conversation.item.create',
      item: expect.objectContaining({
        type: 'message',
        role: 'system',
        content: [expect.objectContaining({ type: 'input_text', text: expect.stringContaining('3 equations') })]
      })
    })
  )
})
```

- [ ] **Step 3: Run to verify it fails**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/service.test.ts -t 'refreshed visualSummary'`
Expected: FAIL.

- [ ] **Step 4: Implement**

In `service.ts`, after the session is created and the agent is registered, set up a subscription that lives for the session's lifetime:

```ts
import { summarizeCurrentPage } from '@/modules/pageCapture'
import { usePlayerStore } from '@/stores/playerStore'

// after session creation:
const pageChangeUnsub = usePlayerStore.subscribe(
  (s) => s.currentPageIndex,
  () => {
    const summary = summarizeCurrentPage()
    const parts: string[] = []
    if (summary.equations > 0) parts.push(`${summary.equations} equations`)
    if (summary.figures > 0) parts.push(`${summary.figures} figures`)
    if (summary.images > 0) parts.push(`${summary.images} images`)
    const text =
      parts.length > 0
        ? `(System note) The user turned the page. It now contains ${parts.join(' and ')}.`
        : `(System note) The user turned the page. It is now text-only.`

    session.transport.sendEvent({
      type: 'conversation.item.create',
      item: {
        type: 'message',
        role: 'system',
        content: [{ type: 'input_text', text }]
      }
    })
  }
)

// On deactivate / session teardown:
pageChangeUnsub()
```

If `currentPageIndex` is not the right field name, substitute the one identified in Step 1.

- [ ] **Step 5: Run tests**

Command: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/service.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "feat(electron): refresh voice-chat visualSummary on page turn"
```

---

## Task 16: Final Verification

- [ ] **Step 1: Type check**

```bash
pnpm --filter rishi-electron tsc --noEmit
```
Expected: no errors.

- [ ] **Step 2: Full test suite**

```bash
pnpm --filter rishi-electron test
```
Expected: all PASS.

- [ ] **Step 3: Manual verification — voice chat vision**

```bash
pnpm --filter rishi-electron dev
```
1. Open a math-heavy PDF in the library.
2. Start voice chat.
3. Ask: "explain the equation in this section."
4. In DevTools console, confirm `[voice-chat] tool 'inspectCurrentPage' ok` appears.
5. Confirm the spoken response references the equation correctly.

- [ ] **Step 4: Manual verification — TTS cue**

1. Same PDF. Start TTS read-aloud near a labeled equation.
2. Confirm the "Equation on page" affordance appears.
3. Click it. Confirm the equation scrolls into view.
4. Continue reading past. Confirm the cue disappears.

- [ ] **Step 5: Manual verification — no-op on plain text**

1. Open a plain-text novel EPUB.
2. Start voice chat. Ask a general question ("who is the protagonist?").
3. Confirm DevTools shows NO `inspectCurrentPage` calls.
4. Confirm the visual-context section in instructions reads "no visual content (text-only page)" — visible only if you log the agent instructions during construction; this is for manual verification once during development.

- [ ] **Step 6: Open PR**

Use `gh pr create` per the repo's standard flow. Reference the spec in the PR description.

