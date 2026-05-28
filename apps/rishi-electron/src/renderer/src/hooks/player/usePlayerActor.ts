// apps/electron/src/renderer/src/hooks/player/usePlayerActor.ts
//
// Actor lifecycle: provide() per-format view actor, create + start, INITIALIZE,
// CLEANUP, setSend wiring, and per-book TTS cancellation on teardown.
import { useEffect, useMemo, useRef, useState } from 'react'
import { createActor, type AnyActorLogic } from 'xstate'
import { playerMachine, type TtsFetcher } from '@/machines/playerMachine'
import { usePlayerStore, type PlayerSend } from '@/stores/playerStore'
import { getTtsService } from '@/services'

export type UsePlayerActorOptions = {
  /**
   * Per-format view actor logic. Provided by the format reader (EpubView →
   * epubViewActor, pdf.tsx → pdfViewActor). The hook overrides the machine's
   * placeholder `view` actor via `.provide({ actors: { view: viewLogic } })`
   * so the invoked actor can drive rendition.next() / page navigation and
   * emit VIEW_CHANGED back to the machine. When omitted, the noop placeholder
   * remains and NAVIGATE_* sends from the machine are dropped — fine for
   * formats that don't trigger view-boundary advances during TTS (azw3/mobi
   * seed all paragraphs at chapter-load time).
   */
  viewLogic?: AnyActorLogic
  /**
   * Format-specific input forwarded to the invoked view actor. Shape depends
   * on viewLogic (EpubViewInput for epub, PdfViewInput for pdf). Carried as
   * unknown because the hook itself is format-agnostic.
   */
  viewInput?: unknown
}

export type PlayerActor = ReturnType<typeof createActor<typeof playerMachine>>

export function usePlayerActor(
  bookId: string,
  options?: UsePlayerActorOptions
): { actor: PlayerActor | null; send: PlayerSend } {
  const sendRef = useRef<PlayerSend>(() => {})
  const [actor, setActor] = useState<PlayerActor | null>(null)

  // Customise the machine when a per-format view actor is provided. Memo on
  // viewLogic identity so EpubView/pdf.tsx can stabilise it with their own
  // useMemo without churning the actor lifecycle.
  const machine = useMemo(
    () =>
      options?.viewLogic
        ? playerMachine.provide({ actors: { view: options.viewLogic } })
        : playerMachine,
    [options?.viewLogic]
  )

  useEffect(() => {
    // The fetcher input is bound here so playerMachine's invoked fetchTtsLogic
    // talks to the real TTS service in production; tests rely on the machine's
    // default noopFetcher and never wait for a real fetch to resolve.
    const ttsFetcher: TtsFetcher = (req) => getTtsService().requestAudio(req)
    const next = createActor(machine, {
      input: { fetcher: ttsFetcher, viewInput: options?.viewInput }
    })

    const send: PlayerSend = next.send
    sendRef.current = send
    usePlayerStore.getState().setSend(send)

    next.start()
    // Seeded by routes/books.$id.lazy.tsx before this hook initializes.
    const resumeParagraphIndex = usePlayerStore.getState().lastPlayedParagraphIndex
    next.send({ type: 'INITIALIZE', bookId, resumeParagraphIndex })
    setActor(next)

    return () => {
      next.send({ type: 'CLEANUP' })
      // Cancel any in-flight or pending TTS requests for this book. Audio is
      // already silenced by CLEANUP → idle (sendTo audio CLEAR_SRC).
      getTtsService().cancelBookRequests(bookId)
      usePlayerStore.getState().setSend(() => {})
      next.stop()
      setActor(null)
    }
  }, [bookId, machine, options?.viewInput])

  return {
    actor,
    // Why: sendRef.current holds the stable send bound in useEffect; callers
    // consume the returned object synchronously. The ref's identity is stable
    // across renders; only its current value swaps when the actor is recreated.
    // eslint-disable-next-line react-hooks/refs
    send: sendRef.current
  }
}
