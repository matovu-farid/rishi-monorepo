import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex } from '@/models/player_control'

// Wave 3 will create src/renderer/src/hooks/reader/useChapterParagraphPrefetch.ts.
const HOOK_PATH = '@/hooks/' + 'reader/useChapterParagraphPrefetch'

type UseChapterParagraphPrefetch = (params: {
  chapterIndex: number
  chapterCount: number
  indexPrefix: string
  fetchCurrent: (idx: number) => Promise<string[]>
  fetchAt: (idx: number) => Promise<string[]>
}) => void

async function loadHook(): Promise<UseChapterParagraphPrefetch> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    useChapterParagraphPrefetch: UseChapterParagraphPrefetch
  }
  return mod.useChapterParagraphPrefetch
}

type ParagraphSetter = (p: ParagraphWithIndex[]) => void
let setCurrentSpy: ReturnType<typeof vi.fn<ParagraphSetter>>
let setNextSpy: ReturnType<typeof vi.fn<ParagraphSetter>>
let setPrevSpy: ReturnType<typeof vi.fn<ParagraphSetter>>

beforeEach(() => {
  vi.useFakeTimers()
  setCurrentSpy = vi.fn<ParagraphSetter>()
  setNextSpy = vi.fn<ParagraphSetter>()
  setPrevSpy = vi.fn<ParagraphSetter>()
  usePlayerStore.setState({
    setCurrentParagraphs: setCurrentSpy,
    setNextPageParagraphs: setNextSpy,
    setPrevPageParagraphs: setPrevSpy
  })
})

afterEach(() => {
  vi.useRealTimers()
})

// Flush pending microtasks (Promise.then callbacks) AFTER advancing fake
// timers so the .then chains scheduled by the hook get to run.
async function flushPromises(): Promise<void> {
  // Two awaits is enough for then→then chains seen in the prefetch hook.
  await Promise.resolve()
  await Promise.resolve()
}

describe('useChapterParagraphPrefetch', () => {
  it('fetches current chapter immediately and pushes paragraphs with prefixed index', async () => {
    const useChapterParagraphPrefetch = await loadHook()
    const fetchCurrent = vi.fn().mockResolvedValue(['hello', 'world'])
    const fetchAt = vi.fn().mockResolvedValue([])
    renderHook(() =>
      useChapterParagraphPrefetch({
        chapterIndex: 2,
        chapterCount: 5,
        indexPrefix: 'azw3',
        fetchCurrent,
        fetchAt
      })
    )
    expect(fetchCurrent).toHaveBeenCalledWith(2)
    await act(async () => {
      await flushPromises()
    })
    expect(setCurrentSpy).toHaveBeenCalledWith<[ParagraphWithIndex[]]>([
      { text: 'hello', index: 'azw3-2-0' },
      { text: 'world', index: 'azw3-2-1' }
    ])
  })

  it('debounces next/prev prefetch by 300ms', async () => {
    const useChapterParagraphPrefetch = await loadHook()
    const fetchCurrent = vi.fn().mockResolvedValue([])
    const fetchAt = vi.fn(async (i: number) => [`chapter-${i}`])
    renderHook(() =>
      useChapterParagraphPrefetch({
        chapterIndex: 3,
        chapterCount: 10,
        indexPrefix: 'mobi',
        fetchCurrent,
        fetchAt
      })
    )
    // Before the debounce fires, only fetchCurrent has been called.
    expect(fetchAt).not.toHaveBeenCalled()
    await act(async () => {
      vi.advanceTimersByTime(300)
      await flushPromises()
    })
    expect(fetchAt).toHaveBeenCalledWith(4)
    expect(fetchAt).toHaveBeenCalledWith(2)
    expect(setNextSpy).toHaveBeenCalledWith([{ text: 'chapter-4', index: 'mobi-4-0' }])
    expect(setPrevSpy).toHaveBeenCalledWith([{ text: 'chapter-2', index: 'mobi-2-0' }])
  })

  it('does not prefetch the next chapter when at the last one', async () => {
    const useChapterParagraphPrefetch = await loadHook()
    const fetchCurrent = vi.fn().mockResolvedValue([])
    const fetchAt = vi.fn(async (i: number) => [`chapter-${i}`])
    renderHook(() =>
      useChapterParagraphPrefetch({
        chapterIndex: 9,
        chapterCount: 10,
        indexPrefix: 'mobi',
        fetchCurrent,
        fetchAt
      })
    )
    await act(async () => {
      vi.advanceTimersByTime(300)
      await flushPromises()
    })
    expect(fetchAt).not.toHaveBeenCalledWith(10)
    // Hook still clears the next slot so stale paragraphs don't linger.
    expect(setNextSpy).toHaveBeenCalledWith([])
    // Previous chapter still prefetches.
    expect(fetchAt).toHaveBeenCalledWith(8)
  })

  it('does not prefetch the previous chapter when at the first one', async () => {
    const useChapterParagraphPrefetch = await loadHook()
    const fetchCurrent = vi.fn().mockResolvedValue([])
    const fetchAt = vi.fn(async (i: number) => [`chapter-${i}`])
    renderHook(() =>
      useChapterParagraphPrefetch({
        chapterIndex: 0,
        chapterCount: 10,
        indexPrefix: 'mobi',
        fetchCurrent,
        fetchAt
      })
    )
    await act(async () => {
      vi.advanceTimersByTime(300)
      await flushPromises()
    })
    expect(fetchAt).not.toHaveBeenCalledWith(-1)
    expect(setPrevSpy).toHaveBeenCalledWith([])
    // Next chapter still prefetches.
    expect(fetchAt).toHaveBeenCalledWith(1)
  })

  it('clears next + prev paragraphs on unmount', async () => {
    const useChapterParagraphPrefetch = await loadHook()
    const fetchCurrent = vi.fn().mockResolvedValue([])
    const fetchAt = vi.fn().mockResolvedValue([])
    const { unmount } = renderHook(() =>
      useChapterParagraphPrefetch({
        chapterIndex: 1,
        chapterCount: 3,
        indexPrefix: 'azw3',
        fetchCurrent,
        fetchAt
      })
    )
    setNextSpy.mockClear()
    setPrevSpy.mockClear()
    unmount()
    expect(setNextSpy).toHaveBeenCalledWith([])
    expect(setPrevSpy).toHaveBeenCalledWith([])
  })
})
