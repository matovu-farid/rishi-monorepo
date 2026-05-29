// apps/electron/src/renderer/src/hooks/player/useResumeWrite.ts
//
// Persists the live paragraph id so reopen can highlight + resume.
// The underlying subscription is exported as `startResumeWriteSubscription`
// so the writePath test (and any non-React callers) can drive it directly.
import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'
import { updateBookLastParagraph } from '@/lib/api'

export function startResumeWriteSubscription({ bookId }: { bookId: number }): {
  dispose: () => void
  flush: () => void
} {
  let pendingId: string | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const writeNow = (id: string): void => {
    void updateBookLastParagraph({ bookId, lastParagraph: id }).catch((err: unknown) => {
      console.warn('[player] resume-paragraph save failed:', err)
    })
  }

  const flush = (): void => {
    if (timer === null || pendingId === null) return
    clearTimeout(timer)
    const id = pendingId
    timer = null
    pendingId = null
    writeNow(id)
  }

  const unsub = usePlayerStore.subscribe(
    (s) => s.activeParagraph,
    (active) => {
      if (active === null) return
      usePlayerStore.setState({ lastPlayedParagraphIndex: active.index })
      pendingId = active.index
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(() => {
        const id = pendingId
        timer = null
        pendingId = null
        if (id !== null) writeNow(id)
      }, 500)
    }
  )

  const dispose = (): void => {
    if (timer !== null) clearTimeout(timer)
    timer = null
    pendingId = null
    unsub()
  }

  return { dispose, flush }
}

export function useResumeWrite(bookId: string): void {
  useEffect(() => {
    // bookId is a string in this hook (xstate context expects string ids);
    // the DB column is keyed by numeric book id.
    const resumeWrite = startResumeWriteSubscription({ bookId: Number(bookId) })
    return () => {
      resumeWrite.flush()
      resumeWrite.dispose()
    }
  }, [bookId])
}
