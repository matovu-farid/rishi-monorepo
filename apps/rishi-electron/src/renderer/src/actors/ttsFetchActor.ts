// apps/electron/src/renderer/src/actors/ttsFetchActor.ts
//
// xstate v5 `fromPromise` actor that owns one TTS fetch lifecycle. The
// playerMachine invokes it on entering `loading`; xstate auto-cancels the
// in-flight promise when the state exits — replacing the manual
// fetch-generation counter used by the pre-actor bridge.
//
// The actor is parameterised by a `fetcher` function so tests can inject a
// stub. Production binds it to `getTtsService().requestAudio` in the
// playerMachine setup.

import { fromPromise } from 'xstate'

export type TtsFetchInput = {
  bookId: string
  /** Cache key — either the paragraph CFI or the partial-first override key. */
  cfiRange: string
  /** Text to synthesise — either the paragraph text or the partial-first text. */
  text: string
  /** Whether to skip-and-auto-advance instead of fetching. True for empty paragraphs. */
  skip: boolean
  /** Resolver injected at machine-create time so tests can stub it. */
  fetcher: (req: {
    bookId: string
    cfiRange: string
    text: string
    priority: number
  }) => Promise<string>
}

/**
 * Result of a TTS fetch invocation.
 *  - `{ kind: 'play', src }` — fetched audio; parent sends PLAY to audioActor
 *  - `{ kind: 'skip' }` — empty paragraph; parent auto-advances via AUDIO_ENDED
 */
export type TtsFetchOutput = { kind: 'play'; src: string } | { kind: 'skip' }

export const fetchTtsLogic = fromPromise<TtsFetchOutput, TtsFetchInput>(async ({ input }) => {
  if (input.skip) {
    // 2-second pause on empty paragraphs so the UI doesn't appear to silently
    // skip pages.
    await new Promise<void>((r) => setTimeout(r, 2000))
    return { kind: 'skip' }
  }
  const src = await input.fetcher({
    bookId: input.bookId,
    cfiRange: input.cfiRange,
    text: input.text,
    priority: 1
  })
  return { kind: 'play', src }
})
