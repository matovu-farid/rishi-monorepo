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
    doc.querySelector('p')!.classList.add(TTS_ACTIVE_CLASS)
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
