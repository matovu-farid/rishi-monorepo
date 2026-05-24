/**
 * Tests for NoteIconOverlay — the in-iframe "note exists here" icon
 * renderer. The module is intentionally framework-free (plain TS class +
 * direct DOM ops) so we can drive it from a JSDOM fixture without epubjs.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { NoteIconOverlay, NOTE_ICON_ATTR } from './note-icon-overlay'

function makeIframeDoc(): Document {
  // happy-dom is the test environment; document.implementation.createHTMLDocument
  // gives us a fresh, isolated document with a body.
  return document.implementation.createHTMLDocument('iframe-fixture')
}

function fakeRange(rects: Array<Pick<DOMRect, 'top' | 'left' | 'right' | 'bottom'>>): Range {
  // Minimal Range stub. The overlay only ever calls getClientRects().
  return {
    getClientRects: () => rects as unknown as DOMRectList
  } as unknown as Range
}

function row(cfiRange: string, note: string): { cfiRange: string; note: string } {
  return { cfiRange, note }
}

let iframeDoc: Document

beforeEach(() => {
  iframeDoc = makeIframeDoc()
})

describe('NoteIconOverlay', () => {
  it('appends a button to the iframe body for a row whose note is non-empty', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => fakeRange([{ top: 10, left: 20, right: 200, bottom: 30 }]),
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:1', 'hello world')])

    const buttons = iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)
    expect(buttons).toHaveLength(1)
  })

  it('does NOT append a button for a row with an empty or whitespace-only note', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]),
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:empty', ''), row('cfi:ws', '   \n\t  ')])

    expect(iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(0)
  })

  it("positions each icon at the top-right of the range's LAST bounding rect (multi-line ranges anchor to the last line)", () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () =>
        fakeRange([
          { top: 10, left: 100, right: 300, bottom: 30 }, // first line
          { top: 40, left: 50, right: 250, bottom: 60 } // last line — anchor here
        ]),
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:multi', 'note')])

    const button = iframeDoc.querySelector(`[${NOTE_ICON_ATTR}]`) as HTMLElement
    expect(button).not.toBeNull()
    // top = rect.top; left = rect.right - icon size (anchored to right edge of last line)
    expect(button.style.position).toBe('absolute')
    expect(parseFloat(button.style.top)).toBe(40)
    expect(parseFloat(button.style.left)).toBeCloseTo(250 - 18, 1) // ICON_SIZE = 18
  })

  it('skips rows whose resolveRange returns null (range not in current view)', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: (cfi) =>
        cfi === 'cfi:present' ? fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]) : null,
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:present', 'a'), row('cfi:absent', 'b')])

    const buttons = iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)
    expect(buttons).toHaveLength(1)
  })

  it('skips rows whose range has no bounding rects (collapsed / not rendered)', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => fakeRange([]),
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:empty-rects', 'note text')])

    expect(iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(0)
  })

  it('calling render again wipes the previous icons and re-renders fresh ones (no duplicates across re-renders)', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]),
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:1', 'a')])
    overlay.render([row('cfi:1', 'a'), row('cfi:2', 'b')])

    expect(iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(2)
  })

  it('destroy() removes every injected icon', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]),
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:1', 'a'), row('cfi:2', 'b')])
    expect(iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(2)

    overlay.destroy()
    expect(iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(0)
  })

  it('clicking a rendered icon invokes onIconClick with the matching cfiRange', () => {
    const onIconClick = vi.fn()
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]),
      onIconClick
    })

    overlay.render([row('cfi:42', 'hi')])
    const button = iframeDoc.querySelector(`[${NOTE_ICON_ATTR}]`) as HTMLButtonElement
    button.click()

    expect(onIconClick).toHaveBeenCalledTimes(1)
    expect(onIconClick).toHaveBeenCalledWith('cfi:42')
  })

  it('exposes the iframeDoc as a public readonly property for identity checks (caller decides when to recreate)', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => null,
      onIconClick: vi.fn()
    })
    // Public access — no bracket-into-private-field hacks at the call site.
    expect(overlay.iframeDoc).toBe(iframeDoc)
  })

  it('destroy() removes icons only from the document this overlay was constructed for (no cross-iframe leaks)', () => {
    // Simulate a rendition swap: build overlay for docA, render some icons.
    const docA = makeIframeDoc()
    const docB = makeIframeDoc()

    const overlayA = new NoteIconOverlay({
      iframeDoc: docA,
      resolveRange: () => fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]),
      onIconClick: vi.fn()
    })
    overlayA.render([row('cfi:1', 'a'), row('cfi:2', 'b')])
    expect(docA.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(2)

    // Caller (EpubView) tears down the old overlay before building a fresh
    // one for the new iframe. This must remove ALL icons from docA so
    // page-turn / reflow doesn't leave phantom buttons in the stale doc.
    overlayA.destroy()
    expect(docA.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(0)

    const overlayB = new NoteIconOverlay({
      iframeDoc: docB,
      resolveRange: () => fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]),
      onIconClick: vi.fn()
    })
    overlayB.render([row('cfi:3', 'c')])
    // New icons land in docB only — docA stays clean.
    expect(docB.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(1)
    expect(docA.querySelectorAll(`[${NOTE_ICON_ATTR}]`)).toHaveLength(0)
  })

  it('tags each icon with its cfiRange so targeted removal is possible', () => {
    const overlay = new NoteIconOverlay({
      iframeDoc,
      resolveRange: () => fakeRange([{ top: 0, left: 0, right: 100, bottom: 20 }]),
      onIconClick: vi.fn()
    })

    overlay.render([row('cfi:a/b!/c,/1:0,/1:5', 'x')])
    const button = iframeDoc.querySelector(`[${NOTE_ICON_ATTR}]`) as HTMLElement
    // The attribute MUST round-trip the cfiRange (we'll need to look it up
    // on click and during targeted removal).
    expect(button.getAttribute(NOTE_ICON_ATTR)).toBe('cfi:a/b!/c,/1:0,/1:5')
  })
})
