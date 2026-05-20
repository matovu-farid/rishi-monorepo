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

  it('does not emit duplicate equation hits when LaTeX appears inside a katex span', () => {
    const body = dom(`<p id="p1">Eq: <span class="katex">$x = 1$</span></p>`)
    const hits = detectVisualsNear(body.querySelector('#p1')!)
    const equations = hits.filter((h) => h.kind === 'equation')
    expect(equations).toHaveLength(1)
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

  it('does not double-count when a <math> element has math-like textContent', () => {
    const body = dom(`<math><mi>x</mi><mo>=</mo><mn>1</mn></math>`)
    // textContent of <math> is "x=1" which contains "=", a math char.
    // It must NOT be counted twice (once as <math>, once as LaTeX text match).
    expect(summarizeVisuals(body)).toEqual({ equations: 1, figures: 0, images: 0 })
  })

  it('counts a large standalone <svg> as a figure', () => {
    const body = dom(`<svg width="400" height="300"></svg>`)
    expect(summarizeVisuals(body)).toEqual({ equations: 0, figures: 1, images: 0 })
  })
})
