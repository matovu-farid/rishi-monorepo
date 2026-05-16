import { useEffect, useRef } from 'react'
import { hasIndexedBookData } from '@/lib/api'
import { getBookImportService, type PageDataInsertable } from '@/services'

type BuildPageData = () => Promise<PageDataInsertable[]>

/**
 * Generate vector embeddings for a book on first open so AI chat has
 * something to search. The check + index pair runs at most once per
 * mount lifetime (guarded by `embeddingsProcessedRef`) and is a noop when
 * `ready` is false (the caller hasn't finished parsing the book yet).
 *
 * NOTE: `buildPageData` is accessed via a ref (React Compiler safe) so the
 * caller can recreate the closure freely without invalidating the effect.
 * The hook owns the call to `hasIndexedBookData` so callers don't need to
 * remember to use the new alias.
 */
export function useBookEmbeddings({
  bookId,
  ready,
  buildPageData
}: {
  bookId: number
  ready: boolean
  buildPageData: BuildPageData
}): void {
  const embeddingsProcessedRef = useRef(false)
  const buildPageDataRef = useRef(buildPageData)

  useEffect(() => {
    buildPageDataRef.current = buildPageData
  }, [buildPageData])

  useEffect(() => {
    if (!ready) return
    if (embeddingsProcessedRef.current) return
    embeddingsProcessedRef.current = true

    void (async () => {
      try {
        const alreadyIndexed = await hasIndexedBookData({ bookId })
        if (alreadyIndexed) return

        const pageData = await buildPageDataRef.current()
        if (pageData.length === 0) return
        await getBookImportService().indexBook(bookId, pageData)
      } catch (err) {
        console.warn('[useBookEmbeddings] failed to generate embeddings:', err)
      }
    })()
  }, [bookId, ready])
}
