import { useEffect, useRef } from 'react'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex } from '@/models/player_control'

const DEBOUNCE_MS = 300

type Fetcher = (chapterIndex: number) => Promise<string[]>

/**
 * Publish paragraphs to the player store for TTS. The current chapter is
 * fetched and pushed immediately; the previous/next chapters are prefetched
 * after a 300 ms debounce so rapid chapter flips don't trigger wasted work.
 *
 * On unmount, the prev/next slots are cleared so the player doesn't keep
 * stale paragraphs from a book the user has navigated away from.
 *
 * NOTE: `fetchCurrent` and `fetchAt` are accessed via refs (React Compiler
 * safe). Callers can pass freshly-created closures every render without
 * causing the effect to re-run.
 */
export function useChapterParagraphPrefetch({
  chapterIndex,
  chapterCount,
  indexPrefix,
  fetchCurrent,
  fetchAt
}: {
  chapterIndex: number
  chapterCount: number
  indexPrefix: string
  fetchCurrent: Fetcher
  fetchAt: Fetcher
}): void {
  const fetchCurrentRef = useRef(fetchCurrent)
  const fetchAtRef = useRef(fetchAt)

  // Keep the refs current without invalidating the prefetch effect.
  useEffect(() => {
    fetchCurrentRef.current = fetchCurrent
  }, [fetchCurrent])
  useEffect(() => {
    fetchAtRef.current = fetchAt
  }, [fetchAt])

  useEffect(() => {
    const toParagraphs = (texts: string[], idx: number): ParagraphWithIndex[] =>
      texts.map((text, i) => ({ text, index: `${indexPrefix}-${idx}-${i}` }))

    // Current chapter — fire immediately.
    void fetchCurrentRef.current(chapterIndex).then((texts) => {
      usePlayerStore.getState().setCurrentParagraphs(toParagraphs(texts, chapterIndex))
    })

    // Debounce prev/next prefetch.
    const timer = setTimeout(() => {
      if (chapterIndex < chapterCount - 1) {
        void fetchAtRef.current(chapterIndex + 1).then((texts) => {
          usePlayerStore.getState().setNextPageParagraphs(toParagraphs(texts, chapterIndex + 1))
        })
      } else {
        usePlayerStore.getState().setNextPageParagraphs([])
      }
      if (chapterIndex > 0) {
        void fetchAtRef.current(chapterIndex - 1).then((texts) => {
          usePlayerStore.getState().setPrevPageParagraphs(toParagraphs(texts, chapterIndex - 1))
        })
      } else {
        usePlayerStore.getState().setPrevPageParagraphs([])
      }
    }, DEBOUNCE_MS)

    return () => {
      clearTimeout(timer)
      // Clear stale prefetch so the player never advances into the wrong
      // book's paragraphs after the view unmounts.
      usePlayerStore.getState().setNextPageParagraphs([])
      usePlayerStore.getState().setPrevPageParagraphs([])
    }
  }, [chapterIndex, chapterCount, indexPrefix])
}
