import { describe, it, expect, vi } from 'vitest'
import { resolveLiveSelection, type RenditionLike, type ViewWithSelection } from '../index'

function makeView(opts: {
  text?: string
  cfi?: string
  rangeCount?: number
  noWindow?: boolean
  noContents?: boolean
  noCfiFn?: boolean
}): ViewWithSelection {
  if (opts.noContents) return { contents: null }
  const text = opts.text ?? ''
  const rangeCount = opts.rangeCount ?? (text.length > 0 ? 1 : 0)
  const range = {} as Range
  const getSelection = vi.fn(
    () =>
      ({
        rangeCount,
        toString: () => text,
        getRangeAt: vi.fn(() => range)
      }) as unknown as Selection
  )
  return {
    contents: {
      window: opts.noWindow ? null : ({ getSelection } as unknown as Window),
      cfiFromRange: opts.noCfiFn ? undefined : vi.fn(() => opts.cfi ?? 'epubcfi(/dummy)')
    }
  }
}

function makeRendition(views: ViewWithSelection[]): RenditionLike {
  return {
    manager: {
      views: {
        forEach: (cb) => views.forEach(cb)
      }
    }
  }
}

describe('resolveLiveSelection', () => {
  it('returns null when rendition is null/undefined', () => {
    expect(resolveLiveSelection(null)).toBeNull()
    expect(resolveLiveSelection(undefined)).toBeNull()
  })

  it('returns null when rendition has no manager', () => {
    expect(resolveLiveSelection({} as RenditionLike)).toBeNull()
  })

  it('returns null when views collection is empty', () => {
    expect(resolveLiveSelection(makeRendition([]))).toBeNull()
  })

  it('returns null when view has no contents', () => {
    expect(resolveLiveSelection(makeRendition([makeView({ noContents: true })]))).toBeNull()
  })

  it('returns null when view contents has no window', () => {
    expect(resolveLiveSelection(makeRendition([makeView({ noWindow: true })]))).toBeNull()
  })

  it('returns null when selection has zero ranges', () => {
    expect(
      resolveLiveSelection(makeRendition([makeView({ text: 'foo', rangeCount: 0 })]))
    ).toBeNull()
  })

  it('returns null when selection text is empty', () => {
    expect(resolveLiveSelection(makeRendition([makeView({ text: '' })]))).toBeNull()
  })

  it('returns null when selection text is whitespace only', () => {
    expect(resolveLiveSelection(makeRendition([makeView({ text: '   \n\t' })]))).toBeNull()
  })

  it('returns null when contents has no cfiFromRange', () => {
    expect(
      resolveLiveSelection(makeRendition([makeView({ text: 'hello', noCfiFn: true })]))
    ).toBeNull()
  })

  it('returns selection from first view that has one', () => {
    const result = resolveLiveSelection(
      makeRendition([makeView({ text: 'hello world', cfi: 'epubcfi(/6/4!/4/2)' })])
    )
    expect(result).toEqual({ cfiRange: 'epubcfi(/6/4!/4/2)', text: 'hello world' })
  })

  it('skips views without a selection and returns the first one that has it', () => {
    const result = resolveLiveSelection(
      makeRendition([
        makeView({ text: '' }),
        makeView({ noContents: true }),
        makeView({ text: 'actual selection', cfi: 'epubcfi(/6/8!/4/2,/1:0,/1:16)' })
      ])
    )
    expect(result).toEqual({
      cfiRange: 'epubcfi(/6/8!/4/2,/1:0,/1:16)',
      text: 'actual selection'
    })
  })

  it('does not throw when cfiFromRange throws', () => {
    const throwingView: ViewWithSelection = {
      contents: {
        window: {
          getSelection: () =>
            ({
              rangeCount: 1,
              toString: () => 'text',
              getRangeAt: () => ({}) as Range
            }) as unknown as Selection
        } as unknown as Window,
        cfiFromRange: () => {
          throw new Error('cfi failed')
        }
      }
    }
    expect(resolveLiveSelection(makeRendition([throwingView]))).toBeNull()
  })
})
