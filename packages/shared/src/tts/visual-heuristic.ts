/**
 * Visual heuristic: classify nearby DOM elements as equation / figure /
 * image hits relative to a paragraph anchor. Ported verbatim from
 * `apps/rishi-electron/src/renderer/src/lib/visualHeuristic.ts`.
 *
 * Pure DOM + regex. Runs anywhere with a DOM (electron, jsdom, happy-dom).
 * Mobile callers don't use this directly — the mobile reader paths
 * provide their own (RN-native) cue.
 */

export type VisualKind = 'equation' | 'figure' | 'image'

export interface VisualHit {
  kind: VisualKind
  /**
   * The classified element. May be `null` for LaTeX matches found by text
   * scanning where no single element owns the match (the match lives in
   * the textContent of an element containing other text).
   */
  element: Element | null
  label: string
}

export interface DetectionOptions {
  /** How many sibling steps before/after the anchor to scan. Default 2. */
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

  let childHasEquation = false
  for (const child of Array.from(el.children)) {
    const inner = classifyElement(child)
    if (inner) {
      hits.push(inner)
      if (inner.kind === 'equation') childHasEquation = true
    }
  }

  if ((direct === null || direct.kind !== 'equation') && !childHasEquation) {
    if (hasLatexEquation(el.textContent ?? '')) {
      hits.push({ kind: 'equation', element: el, label: 'equation' })
    }
  }
}

export function detectVisualsNear(anchor: Node, opts: DetectionOptions = {}): VisualHit[] {
  const radius = opts.siblingRadius ?? 2
  const rawHits: VisualHit[] = []

  if (anchor.nodeType !== Node.ELEMENT_NODE) return rawHits
  const el = anchor as Element

  scanElement(el, rawHits)

  let prev: Element | null = el.previousElementSibling
  for (let i = 0; i < radius && prev; i++) {
    scanElement(prev, rawHits)
    prev = prev.previousElementSibling
  }

  let next: Element | null = el.nextElementSibling
  for (let i = 0; i < radius && next; i++) {
    scanElement(next, rawHits)
    next = next.nextElementSibling
  }

  const seen = new Set<Element>()
  const hits: VisualHit[] = []
  for (const hit of rawHits) {
    if (hit.element === null) {
      hits.push(hit)
    } else if (!seen.has(hit.element)) {
      seen.add(hit.element)
      hits.push(hit)
    }
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
    const tag = node.tagName.toLowerCase()
    const hit = classifyElement(node)
    if (hit) {
      if (hit.kind === 'equation') {
        equations++
      } else if (hit.kind === 'figure') {
        if (tag === 'img') {
          if (node.parentElement?.tagName.toLowerCase() !== 'figure') {
            images++
          }
        } else {
          figures++
        }
      } else if (hit.kind === 'image') {
        images++
      }
    }
    node = walker.nextNode() as Element | null
  }

  const rootClone = root.cloneNode(true) as Element
  for (const mathEl of Array.from(
    rootClone.querySelectorAll('math, [class*="mathjax"], [class*="katex"]')
  )) {
    mathEl.parentNode?.removeChild(mathEl)
  }
  const text = rootClone.textContent ?? ''
  for (const re of LATEX_DELIMS) {
    re.lastIndex = 0
    let m: RegExpExecArray | null
    while ((m = re.exec(text)) !== null) {
      if (MATH_CHARS.test(m[1])) equations++
    }
  }

  return { equations, figures, images }
}
