import { describe, it, expect, beforeEach } from 'vitest'
import { useSelectionStore } from './selectionStore'

describe('selectionStore', () => {
  beforeEach(() => {
    useSelectionStore.getState().clear()
  })

  it('starts with no selection', () => {
    expect(useSelectionStore.getState().current).toBeNull()
  })

  it('stores an EPUB selection', () => {
    useSelectionStore.getState().setEpubSelection({
      cfiRange: 'epubcfi(/6/4!/4/2/1,/1:0,/1:5)',
      text: 'hello'
    })
    const sel = useSelectionStore.getState().current
    expect(sel).not.toBeNull()
    expect(sel!.format).toBe('epub')
    expect(sel!.cfiRange).toBe('epubcfi(/6/4!/4/2/1,/1:0,/1:5)')
    expect(sel!.text).toBe('hello')
  })

  it('clear() removes the selection', () => {
    useSelectionStore.getState().setEpubSelection({
      cfiRange: 'epubcfi(/6/4!/4/2/1,/1:0,/1:5)',
      text: 'hello'
    })
    useSelectionStore.getState().clear()
    expect(useSelectionStore.getState().current).toBeNull()
  })

  it('replacing a selection overwrites the old one', () => {
    const store = useSelectionStore.getState()
    store.setEpubSelection({ cfiRange: 'cfi-a', text: 'first' })
    store.setEpubSelection({ cfiRange: 'cfi-b', text: 'second' })
    expect(useSelectionStore.getState().current?.text).toBe('second')
  })
})
