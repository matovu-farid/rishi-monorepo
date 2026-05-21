// @vitest-environment happy-dom
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
    const p = paragraphElement(
      `<div><p id="x">text</p><figure><img width="200" height="200"/></figure></div>`
    )
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
