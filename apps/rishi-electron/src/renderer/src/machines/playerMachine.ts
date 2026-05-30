// apps/electron/src/renderer/src/machines/playerMachine.ts
//
// Phase 3.3 — fromPromise + audioActor wiring.
//
// The machine no longer relies on an external bridge to fetch TTS or drive the
// audio element. It invokes:
//   - audioActor (fromCallback) at root, so PLAY/PAUSE/RESUME/STOP/CLEAR_SRC
//     commands are sendTo'd from this graph and audio→machine events flow
//     back via sendBack.
//   - fetchTtsLogic (fromPromise) inside `loading`, so xstate auto-cancels
//     in-flight TTS fetches on state exit (replaces fetchGeneration counter).
import { setup, assign, sendTo, raise, fromCallback } from 'xstate'
import type { ParagraphWithIndex } from '@/stores/playerStore'
import { audioActor, audioElement } from '@/actors/audioActor'
import { fetchTtsLogic, type TtsFetchInput } from '@/actors/ttsFetchActor'
import type { ViewActorCommand } from '@/actors/viewActor'

const MAX_RETRIES = 3

/** Signature the renderer binds to getTtsService().requestAudio. */
export type TtsFetcher = TtsFetchInput['fetcher']

/**
 * Default fetcher — a forever-pending promise. Real wiring (usePlayerMachine)
 * passes a production fetcher via `input.fetcher` when calling createActor.
 * Tests that don't care about the loading state can rely on this so they
 * don't accidentally trigger real network calls; the state's exit cancels
 * the pending promise.
 */
const noopFetcher: TtsFetcher = () => new Promise<string>(() => {})

// Placeholder view actor used when no per-format actor is provided via
// `.provide({ actors: { view: epubViewActor | pdfViewActor } })`. The default
// is a no-op so machines created without a view actor (e.g. legacy tests that
// exercise the state graph without navigation) don't crash on entry actions
// that sendTo('view', ...).
const noopViewActor = fromCallback<ViewActorCommand, unknown>(() => () => {})

export type PlayerMachineInput = {
  fetcher?: TtsFetcher
  /** Defaults to the singleton audioElement. Tests can pass a fake. */
  audio?: HTMLMediaElement
  /**
   * Format-specific input for the view actor. The shape depends on which
   * actor is provided via `.provide({ actors: { view: epubViewActor } })`:
   * EpubViewInput for epub, PdfViewInput for pdf, etc. Carried as unknown
   * because the machine itself is format-agnostic.
   */
  viewInput?: unknown
}

export type PlayerMachineContext = {
  bookId: string
  paragraphIndex: number
  direction: 'forward' | 'backward'
  currentParagraphs: ParagraphWithIndex[]
  nextPageParagraphs: ParagraphWithIndex[]
  prevPageParagraphs: ParagraphWithIndex[]
  errors: string[]
  retryCount: number
  timedOut: boolean
  // True if the player should auto-resume loading the new page after an
  // external PAGE_NAVIGATING event. Set when nav fires from an active state
  // (playing/loading/paused); false from stopped/idle (user is silent).
  wantsAutoResume: boolean
  // True when CHAT_STARTED interrupted active playback (or loading / waiting-
  // for-paragraphs). On CHAT_ENDED the player auto-resumes from the same
  // paragraphIndex. Reset on every CHAT_ENDED and on any transition that
  // represents the user choosing silence (PAUSE, STOP, etc.).
  wantsAutoResumeAfterChat: boolean
  // Partial-first override: when PLAY_FROM is sent, these fields allow the
  // audio engine to start playback from the middle of a paragraph (e.g. from
  // a user's text selection). partialFirstParagraphIndex tracks WHICH
  // paragraph the override applies to so it can be cleared after that
  // paragraph finishes playing.
  partialFirstText: string | null
  partialFirstKey: string | null
  partialFirstParagraphIndex: number | null
  resumeParagraphIndex: string | null
  /**
   * TTS fetcher resolved from input at createActor time. Stored in context
   * so the loading-state invoke can read it without import-side coupling.
   * Non-serialisable — the machine is not persisted across sessions today.
   */
  fetcher: TtsFetcher
  /**
   * Format-specific input forwarded to the invoked view actor. Stored in
   * context so the root `invoke` block can read it via `({ context }) =>
   * context.viewInput` without import-side coupling. Non-serialisable.
   */
  viewInput: unknown
}

export type PlayerMachineEvent =
  | { type: 'INITIALIZE'; bookId: string; resumeParagraphIndex?: string | null }
  | { type: 'PLAY' }
  | { type: 'PAUSE' }
  | { type: 'RESUME' }
  | { type: 'STOP' }
  | { type: 'NEXT' }
  | { type: 'PREV' }
  | { type: 'AUDIO_LOADED' }
  | { type: 'AUDIO_ENDED' }
  | { type: 'AUDIO_ERROR'; error: string }
  | { type: 'PARAGRAPHS_UPDATED'; paragraphs: ParagraphWithIndex[] }
  | { type: 'NEXT_PARAGRAPHS_UPDATED'; paragraphs: ParagraphWithIndex[] }
  | { type: 'PREV_PARAGRAPHS_UPDATED'; paragraphs: ParagraphWithIndex[] }
  | { type: 'CHAT_STARTED' }
  | { type: 'CHAT_ENDED' }
  | { type: 'CLEANUP' }
  // External page navigation has started — the format reader (epubjs page-curl,
  // PDF virtualizer scroll, AZW3 chapter advance, etc.) is mid-transition and a
  // VIEW_CHANGED / PARAGRAPHS_UPDATED will arrive later. The player must
  // immediately stop playback on the OLD page so the user doesn't hear the
  // previous paragraph during the transition.
  | { type: 'PAGE_NAVIGATING'; direction: 'forward' | 'backward' }
  // Jump directly to a specific paragraph (e.g. from a text selection), with
  // an optional override for the first chunk of audio so playback can begin
  // mid-paragraph. Ignored from idle/pageNavigating/republishingParagraphs.
  | { type: 'PLAY_FROM'; paragraphIndex: number; partialFirstText: string; partialFirstKey: string }
  | { type: 'REPEAT' }
  // Emitted by the view actor when a navigation request did NOT yield a
  // new view (end of document, image-only page, format reader reported it
  // can't advance, etc.). The player transitions to `stopped` with a
  // meaningful reason instead of timing out or — the bug this kills —
  // silently republishing the OLD view's paragraphs and snapping to
  // paragraph 0.
  | { type: 'NAV_NO_PROGRESS'; reason?: 'end-of-document' | 'no-relocation' | 'timeout' }
  // Emitted by the invoked view actor (epub/pdf/etc) when a navigation or
  // republish committed a non-empty new view. Re-raised at the root as
  // PARAGRAPHS_UPDATED so every existing state handler processes it
  // identically — this decouples per-state behaviour from whether paragraphs
  // arrived via store subscription or view-actor sendBack.
  | { type: 'VIEW_CHANGED'; locator: string; paragraphs: ParagraphWithIndex[] }

const initialContext: Omit<PlayerMachineContext, 'fetcher'> = {
  bookId: '',
  paragraphIndex: 0,
  direction: 'forward',
  currentParagraphs: [],
  nextPageParagraphs: [],
  prevPageParagraphs: [],
  errors: [],
  retryCount: 0,
  timedOut: false,
  wantsAutoResume: false,
  wantsAutoResumeAfterChat: false,
  partialFirstText: null,
  partialFirstKey: null,
  partialFirstParagraphIndex: null,
  resumeParagraphIndex: null,
  viewInput: undefined
}

export const playerMachine = setup({
  types: {
    context: {} as PlayerMachineContext,
    events: {} as PlayerMachineEvent
  },
  actors: {
    audio: audioActor,
    fetchTtsLogic,
    view: noopViewActor
  },
  guards: {
    hasParagraphs: ({ context }) => context.currentParagraphs.length > 0,
    hasMoreParagraphs: ({ context }) =>
      context.paragraphIndex < context.currentParagraphs.length - 1,
    hasRetries: ({ context }) => context.retryCount + 1 < MAX_RETRIES,
    isFirstParagraph: ({ context }) => context.paragraphIndex <= 0,
    wasTimedOut: ({ context }) => context.timedOut,
    wantsAutoResumeAfterChat: ({ context }) => context.wantsAutoResumeAfterChat,
    hasUnresolvedResume: ({ context, event }) => {
      if (context.resumeParagraphIndex === null) return false
      if (event.type !== 'PARAGRAPHS_UPDATED') return false
      return event.paragraphs.some((p) => p.index === context.resumeParagraphIndex)
    }
  },
  actions: {
    storeBookId: assign({
      bookId: ({ event }) => (event.type === 'INITIALIZE' ? event.bookId : '')
    }),
    storeResumeIndex: assign({
      resumeParagraphIndex: ({ event }) =>
        event.type === 'INITIALIZE' ? (event.resumeParagraphIndex ?? null) : null
    }),
    resetIndex: assign({ paragraphIndex: 0, retryCount: 0, timedOut: false }),
    resetIndexByDirection: assign({
      paragraphIndex: ({ context }) =>
        context.direction === 'backward' ? Math.max(0, context.currentParagraphs.length - 1) : 0,
      retryCount: 0
    }),
    advanceIndex: assign({
      paragraphIndex: ({ context }) =>
        Math.min(context.paragraphIndex + 1, context.currentParagraphs.length - 1),
      direction: 'forward' as const,
      retryCount: 0
    }),
    retreatIndex: assign({
      paragraphIndex: ({ context }) => Math.max(context.paragraphIndex - 1, 0),
      direction: 'backward' as const,
      retryCount: 0
    }),
    storeParagraphs: assign({
      currentParagraphs: ({ event }) =>
        event.type === 'PARAGRAPHS_UPDATED' ? event.paragraphs : []
    }),
    storeNextParagraphs: assign({
      nextPageParagraphs: ({ event }) =>
        event.type === 'NEXT_PARAGRAPHS_UPDATED' ? event.paragraphs : []
    }),
    storePrevParagraphs: assign({
      prevPageParagraphs: ({ event }) =>
        event.type === 'PREV_PARAGRAPHS_UPDATED' ? event.paragraphs : []
    }),
    incrementRetry: assign({
      retryCount: ({ context }) => context.retryCount + 1
    }),
    logError: assign({
      errors: ({ context, event }) => {
        const msg = event.type === 'AUDIO_ERROR' ? event.error : 'Unknown error'
        const errs = [...context.errors, msg]
        if (errs.length > 50) errs.shift()
        return errs
      }
    }),
    // fetchTtsLogic onError carries the rejection via `event.error`; pull
    // that into the context.errors array using the same 50-item cap.
    logErrorFromInvoke: assign({
      errors: ({ context, event }) => {
        const err = (event as { error?: unknown }).error
        const msg =
          err instanceof Error ? err.message : typeof err === 'string' ? err : 'TTS fetch failed'
        const errs = [...context.errors, msg]
        if (errs.length > 50) errs.shift()
        return errs
      }
    }),
    setDirectionForward: assign({ direction: 'forward' as const }),
    setDirectionBackward: assign({ direction: 'backward' as const }),
    setNavDirection: assign({
      direction: ({ event }) =>
        event.type === 'PAGE_NAVIGATING' ? event.direction : ('forward' as const)
    }),
    // Clear the current paragraph view. When an external page navigation
    // starts, the on-screen paragraphs are about to be replaced; clearing
    // them prevents PLAY from racing the format reader and fetching the
    // old page's paragraph 0.
    clearCurrentParagraphs: assign({
      currentParagraphs: [] as ParagraphWithIndex[],
      paragraphIndex: 0
    }),
    clearErrors: assign({ errors: [] as string[] }),
    setWantsAutoResume: assign({ wantsAutoResume: true }),
    clearWantsAutoResume: assign({ wantsAutoResume: false }),
    setWantsAutoResumeAfterChat: assign({ wantsAutoResumeAfterChat: true }),
    clearWantsAutoResumeAfterChat: assign({ wantsAutoResumeAfterChat: false }),
    flagTimedOut: assign({ timedOut: true }),
    logLoadingTimeout: assign({
      errors: ({ context }) => {
        const errs = [...context.errors, 'Audio loading timed out']
        if (errs.length > 50) errs.shift()
        return errs
      }
    }),
    clearTimedOut: assign({ timedOut: false }),
    resetAll: assign(() => ({ ...initialContext })),
    setPartialFirst: assign({
      partialFirstText: ({ event }) => (event.type === 'PLAY_FROM' ? event.partialFirstText : null),
      partialFirstKey: ({ event }) => (event.type === 'PLAY_FROM' ? event.partialFirstKey : null),
      partialFirstParagraphIndex: ({ event }) =>
        event.type === 'PLAY_FROM' ? event.paragraphIndex : null
    }),
    clearPartialFirst: assign({
      partialFirstText: null,
      partialFirstKey: null,
      partialFirstParagraphIndex: null
    }),
    setParagraphIndexFromEvent: assign({
      paragraphIndex: ({ event }) => (event.type === 'PLAY_FROM' ? event.paragraphIndex : 0)
    }),
    // Check BEFORE advanceIndex: if partialFirstParagraphIndex matches the
    // current (pre-advance) paragraphIndex, this is the paragraph the override
    // applied to — clear it. Otherwise leave it in place for a future paragraph.
    applyResumeIndex: assign({
      paragraphIndex: ({ context, event }) => {
        if (event.type !== 'PARAGRAPHS_UPDATED') return context.paragraphIndex
        const idx = event.paragraphs.findIndex((p) => p.index === context.resumeParagraphIndex)
        return idx >= 0 ? idx : context.paragraphIndex
      },
      resumeParagraphIndex: null
    }),
    clearPartialFirstIfConsumed: assign({
      partialFirstText: ({ context }) =>
        context.partialFirstParagraphIndex === context.paragraphIndex
          ? null
          : context.partialFirstText,
      partialFirstKey: ({ context }) =>
        context.partialFirstParagraphIndex === context.paragraphIndex
          ? null
          : context.partialFirstKey,
      partialFirstParagraphIndex: ({ context }) =>
        context.partialFirstParagraphIndex === context.paragraphIndex
          ? null
          : context.partialFirstParagraphIndex
    })
  }
}).createMachine({
  /** @xstate-layout N4IgpgJg5mDOIC5QAcA2BDAnmATgYgGEAZAUQEEA5AVQAUBtABgF1EUB7WASwBdO2A7ViAAeiAKwB2ADQhMiAExiGAOgCcYgMzyALAEYJDMbu0N5ugL7mZaLLkIAJMgBUA+iQoAREh8YskIZA4ePkF-UQRJGTkEADZVHWUY3XkzbQ1dGPlVCTFLawxsfAJHV3cvH10-di5eASFwlIZVZXSJLRiJVXUGXSjEA01lBhixAA42zpjtLLyAgrsANQBJEgB1F2LKAHFvXyFAmpD6hUUxZWTdMUkNVQ7TPoRk2ZtC5U4IVDA8JYolpyWyEQlgAtEh7fwHYJ1MKIG4xUbKHIaMTqFJXAwaB4mBGXKbaSZXXSGZ7zHBvD5fTauADKTjIACUnLtmPsgrVQqBwkZVNplPIGO1jNNJKoHhpkUMsjztEYjKMRiTbGTYNw2MhkJA8DQiGQAJrg6pQjkiWHafEtCSjXTi5JKHmY2Sw-S6ZQmbSqUb4trTGKK14qtUaiBanX6yqsw7QzkKMYqZKGW4xDSjDQxLFJ+SS7SjeJifkaUx+3DKAPqzUUEgADScBoCbKOMIQGjNEgtVptiiaaQeWQSKPFKLi8pzGiLytVZeDFerdHDEPrUZNCDM4qGSnlGgkyU6tx7o3GiIY42tTWGDDSY5LE6DWvpJAWtch7OOy+tGjXR6TW-kO7TjuXHq8hk+gSIo4yps2l6ljeNB3g+c6Gs+jbNuam7tuknb2mKKQuqohitJaKbulB16ajQDJkFs9JkDQ9jUi4tAeM4zJVHWkbGuEKGtmhb62l2DrRAWZhDDKVrxPGEi+lYcxKlegZkRRVE0XRDE0ExTIVKxT4NtGTZfoikiXPE2Roto2HqGo2QGHEugZNkJHycG5HUUptH0YxzE+PIWkLhxsJxCo4wMEe3qplaYq6F0yhiGaUwSHo7rJg5k54NOrjOZR1Fuap6ksRGRovpuCTaFMhhJukeEChFApDKolzjHVVqdMlMFwS4GWuSpHkaY+vmFaBZy6KM8gplMtnjCVYrBTEiTJnmnqpPILUKTsLgUGQyxbM4PxbL17EvooBjnPyg5JqN2ExDNRn2p6RKQdJLzFtBZGhi4ABi9IAPIALJ7QVyEtm2vGYd2-42giyISFDbQ9G0uQPaSckpVSLi0gyPUsvO+3IW0LomFcSbqG0WR7imfJaHoYzxKm8P5LJqBsOgECcPwUB4BAAhgG8-AAG5sAA1lzj1kgzTMs1ACAs3zADG6Dsr4f1Ibp+LDK6mgMAY8jJtMZlg0SmbxPu7qqOK3q0zJryi8zrPs5z3N84LyjC8oVvi5LvNsLL8vMLOPnY8rcSZmhtymERXRTU0rqSQWoFWh0EiXq7Nu4DgbBkjY3AAGZpwAtk7iNJxLUue3LIQK5jiE6UuJV1coG4-jKOQCiMpPNBrPS2UkNxGInjPW2zKdp-ncvZzgefO4X7sy6XAgKwhbH-bplozZoVy3Eo1rxaMDxTGIM3BcimSpvF+i92LNtkFQHhLJ9LhEJ9ZDlIrVecfF5zwu3ZpNHvzY75agWjE0J6SQR8loI3pn3cWeBL7X1viQekX16TP0XOEFWvJhgrimF0aUPZJJnEujcLoR5sy3ATuAy2kCL5Xxvm4BBn0kHz20ig-o8porIkHBvTc2Yd7GBdIOHQHotxJDIXTCh582YwJoWUPKWNF7Vw6GcCadVJIGBzNIf88gpiZkOvuEYVwFpn37tA6hcDPC7EYX1ZCI18E6CGlrfEMVf7-kilaOunoBTJgmiVUYhioHkSoNSMEFcF5KyXFoQBiRbHDWbDkNIutoj62aFcGUOhOg03NhPShbMOpZS6mpTyyC-IIHxIoPkgDzwpmRJTHsco65GChiYTRlpJK+JtrST69BglMKKVxIGHY7Sg0EmaF00d9wehjjmKSojiyF0IKQSgtBCkvmmKuJMJUSodEGbCVIrpDCw0mJdHQrTsmURIGtDaSwtr-AoLtLpljdJShUEmMYYU5Th3-NmKYQwtzui1sNLoIiLYzKySGPU70vq-Tuf7auoEVDTFuMNHMq8xA9m7q6GUwxLjGFTBYchwLxEOGcKjOkjIZGV2YU2axkS9DRIcXEh4eErrZj0CkKYMRgraGOXgYQKo5Zc3QJnbguAAAU7LgoMAAJR4EyeIpZjZvzRRGO6eUPR4SZAeI4vhGR2V5lsuvS8Lw-GX0CXKh5np36jE-iYdQayHiRUjtmSQPR1xGQyYjQ1bSnAdNNWE88FqrXf1tRorIM1OjnnWUeIagLnYeokSYtwZifBQrkQ0Zs-qDBfxtU46IaRMwZmGmaQBVoHEGoKFAyRpin4WOhZxYw6bw2BuzQoMNkSkhGASkkMB0z05lptmlH1DQYr1szT-eJiARiZl+SGpQNoZSlqwFA-t1aU3bKAh-DN1rR09h5CoD0mg7I5FuF2oFPaF021gveAdsI00ZEtRuxtY6mzDF5DcYwWQlAbw6POzAfi4K+3yqEhoZph2bqDdEAmQwbhawMMMK4MVv1Gpcrk9y+SMZ+xXcuL5t6A1ZsfVvNQMpD7io1qmBDfaqzpUUshnKBTk2AcQENXCkkSqWhikkM0j7LoHlGviS6cGtxkeyW1HJykUO5STeh+jjxhqJFRPiE2ol9wov-CMWu2tYZvrsW62SsbjGwNoYgq9TYh3YfvbhnhNxLLnjwZvS4gmtSnPOZtbaNyjMoRAw+sUlpMztlAuKVoE77PajBR9H6bm36mYbeZlTSQVD8hhvoTQHofF4tPT+m2d4aDkBrHRl+-k113qi1ulTGE+RQ3FJookfn7MozRqSiTAG8vLgi+uorYGGPL2+TmMZRNxQGvQAAV1gJqdpnTJNNYyAWV04pCPJBuOkZT0R+Sq1TGVc8AoURztS07Qbw2pwUaMxkYK03mz7q1ibS4dqfzvi3EeAUKYNP9aG+WA7y6pNGThTNs783LsaMI5ZZEpgOg-js9t5Au2yJ-tyxS+qn3TsYR+4tmMSh0UjEyHZfEnKwcQ6cn+t7E3Mhw9m+dhbdrphPLircLQeZFBPb26lCj7UqOiZo2hxrMOY6IihpkB72IBIMZinwnoGsSpNHGF+7Hz3cf3iZ0hln3UyUhImwWBE7pSopncdcMnMoRKWqxdaca2nXjg6lw51a61nPXNueNmHTqTvE8R2KbxuyDBEjEuKcYdPNS1ZJWz2R73UyZg1sNexyITaimcc2BEm31B70m5tr3EBlDS0+OgfgeA7zUioN9IJNuikq1kybb+OhFCKB7JcdBSYkiXXhPGKZJ6dtS+T6n9PInsoK4a-7ibwUg-xRKiruIaRejOI14kSQSg9A3GGKBRPzewBp9BbqcFYXodFMm0T77F2kePHqecfQgCxhmA9Jo2fvLPgZ5IFnnPh3Yv2836TyPR0MixRtAKZ1p-uDoHP23vJ4nDt-IMhpitE3iMDtViTVjSDCjiD3j3g-y-y+GCyX1C0hTzxfA+zvwRy3ztUuBUALBrhPFsnqkvAAHd0BghWY3o04aB0AcB0AoBaDkAAALWABzOXdvVDRXbpA6EjD8Dcb8X8O1TZFoMwEQ4PSKaNRGUg8gqASgnAag2g+g9AJglgi3NaW+WCT6KiS-akIzMwa0Xgr8bcLoP8JbFEQaFITcTIEaDIHIEgsg3gCgqgmgughg5gvAUbXQu6AwzcIw3cP7LcREXEQwyQPQOw6Q2Q+QlwpQtw8ic3C5K5HaXQngvZPg3wkw-yPMRVZsfkKrT0eKMIhwmQpwhQ1wlgxA5fFA9nIpfkMmFIwwn8Ywu1AtRIS1KyKw+IAo8WCI5wxQ5QwlGkX3Tg+5JcS4I6SAh3LAjRNlOuYwswGvLWUcbbKQwo7oko6IlgnlT-IVZQAVIVHAYVIkcVKVZ2ZYro4oqI5QzwrWbw-gxojReKM4bMVIECEaJFS8HAMAZAAbAAI1QE4FgEYPFkiN6JiOZ3YL-1XxfHAldC6EUGtB5Dhg1R0EUXZRTHikkkm3eM+J+L+IBKBJ6NKNSg2jUPai+i0OpB0MhPlXiFdHGHqXsQJCxHSF5FuEinFC6BlFuCxK+N+P+MBNZmBMJI8KpN0ktUnTpP0AZPXixDSAhg-hKjzFTGIm2w+J5NxP5KgEFPWLNzOQt0uRc2tyqKhNuBaA1mMiyB6FEixGf0SFMEkk9Aqy227WUFVJxL5PxLWL6J93RiGJrQUHSARGDw5R6FhK2WKTGF5EVL3kInfWPWdldN5LxIFIJO1M2L5R2MFRFUOOCmOMRgTPVI9IuOYKM2hONjhJuHxGRCxByEzAaUPWbg1gkJ0zoLAAoHQB5k4CgFLnPTBN-1o1QMbEOjjBOkTGTFTA1QqT5BGhyIITZP6xgDbI7K7MKNYMynlw4M0iNMHLt3jFOjHPSKbGTCSRrx-k0BKlxWdPBwXPbM7O7LZlUIoHULJMz0pIHIeR3JHIIXOjBiSzUE0WmCGg9CGix0vJbMXNvJXOFLfKXCHOOgTC-PHLBgCjKX0QePUHulAuvKXLvMX10OlHOHrKJBRDdwPKKgRC1mtEbnilI2xywogqNQCVzy3IeRNgRB5Dqk5M7lGLFCTBGW83lB-EkmCibONzApvOXKNTiMt0SJFJgoRPOCaCP0kiSGfzFFXmEJpw6EtVunrxjTEuwpXLSllzXPBP7OYrkpqg4tVXrmMCd2TDrlAhsJGmxFp1otbPEpwovQWGMs6jEzMq7wpQtN5AzDV3UBwPkDFGyNdEiiq2aQpnnPcoMqgW9PqzwqJDqRpzNFuCJmwkiiGGSC6DzEPziEWMwsSvoptjTO2N2KzOI1zObLooktZl0NjDgr3O-MEncUSEI3VnPEUF0sRkHnwH7VkvCFAkzBgOVXZVvXVX-FQqnPFQLE3HbUvCGoZxnHx1tzGK+0wIf0EhwmigRMAQxK1lWpwFTnwC8sOzt3GPv1+0ElOyGGCm6wtOcrOoutvEvU2qKU62RXXh6C4W3jmsAhaAuxNnZQMFUHerTncK9TG3MrGtMEVRig9GmrVQio+XlBXmzB6B62MAGtkjWsQKM3igmqVVRustmvAxVTUCCitCDORGhsuscz1ISNc1GvHRpMmoppmoxsEkTDUFd3aH5AbhAobyJtemQJJq0GRqmspr5vEFu1bVsgJjRxS2dLWpSr93JTX3ZWaDimF2SSSGGh3j6paHGmGjiByGGksGkn4DYAgDgH2FJARsQAj2iDwjVgLBjwUTwnVob3eE+FduKRlDOABT3nXiFvTHfDSB1Q3VsQ1mWggGDvSEs3Vj0HPDmg-Sd2KnDUih1mSDFplX7hTvUEDL0AIMMAGGwh6BaHbFzGOo6LB17SgGDuMDOApkuBwnPJUT-hzDKRHGryRREuLBNz22DsyEGnZRiVPC0XUQSSSGaHUEnwzoITGFnxT3n2NC4MbA6HfCOxnsZWmHnoY1LIPzzEtGpySklz2yvHgLbtK0n2r1AnhHiyaJkxVSypuAEsLCWPsLOLkJTOULbsAV5GFHhUtDZKGm3U3HOCU2bGTGY2GG5LdKTM1KAeYIntKWxXkwRRAQVuKQVWMnlPjGQbcvAqatboCuqPc00RilVSPMLrFH+RaK-gvsIKhu2yGono1jXHdAyCyFiipvHX0BUCEU6CKo9CbssCAA */
  id: 'player',
  initial: 'idle',
  context: ({ input }) => {
    const i = input as PlayerMachineInput | undefined
    return {
      ...initialContext,
      fetcher: i?.fetcher ?? noopFetcher,
      viewInput: i?.viewInput
    }
  },
  invoke: [
    {
      // Always-on audioActor. Lives for the lifetime of the parent. All
      // PLAY/PAUSE/RESUME/STOP/CLEAR_SRC commands are sendTo('audio', ...).
      // Audio→machine events (AUDIO_LOADED / AUDIO_ENDED / AUDIO_ERROR) flow
      // back as parent events via sendBack and are handled by the on:
      // blocks of whichever state the parent is in.
      id: 'audio',
      src: 'audio',
      input: { audio: audioElement }
    },
    {
      // Always-on view actor — per-format (epubViewActor, pdfViewActor, ...)
      // injected via `.provide({ actors: { view: epubViewActor } })` at the
      // reader-screen layer. Receives NAVIGATE_NEXT/PREV/TO/REPUBLISH;
      // emits VIEW_CHANGED / NAV_NO_PROGRESS back. Default is a no-op so
      // tests that exercise the state graph without navigation don't crash.
      id: 'view',
      src: 'view',
      input: ({ context }: { context: PlayerMachineContext }) => context.viewInput
    }
  ],
  on: {
    CLEANUP: {
      target: '.idle',
      actions: ['resetAll', sendTo('audio', { type: 'CLEAR_SRC' })]
    },
    // Voice chat ended. If we paused playback for the chat (flag set on
    // CHAT_STARTED from playing/loading/waitingForParagraphs), re-enter loading
    // at the same paragraphIndex to auto-resume. Otherwise just clear the
    // flag — the user either wasn't listening or paused intentionally during
    // the chat. The flag is always cleared on this event.
    CHAT_ENDED: [
      {
        guard: 'wantsAutoResumeAfterChat',
        target: '.loading',
        actions: ['clearWantsAutoResumeAfterChat']
      },
      {
        actions: ['clearWantsAutoResumeAfterChat']
      }
    ],
    // The view actor reports a committed view. Re-raise as PARAGRAPHS_UPDATED
    // so every existing state handler (loading, playing, waitingForParagraphs,
    // pageNavigating, republishingParagraphs, etc.) processes it identically.
    // This decouples per-state event graph from whether paragraphs arrived
    // via store subscription or view-actor sendBack.
    VIEW_CHANGED: {
      actions: raise(({ event }) => ({
        type: 'PARAGRAPHS_UPDATED' as const,
        paragraphs: (event as { paragraphs: ParagraphWithIndex[] }).paragraphs
      }))
    }
  },
  // Note: PAGE_NAVIGATING is handled per-state below (not as a global handler)
  // because behaviour differs:
  //   - from playing/loading/paused we set wantsAutoResume and transition to
  //     pageNavigating, AND clear stale currentParagraphs (the old page's
  //     paragraphs must not persist into the new page);
  //   - from stopped we transition to pageNavigating WITHOUT clearing
  //     paragraphs — nothing's playing so there's no urgency, and clearing
  //     would cause a fast PLAY-during-nav to route to waitingForParagraphs
  //     and emit a spurious NAVIGATE_NEXT (double-nav bug);
  //   - from idle the event is dropped (no book is open yet).
  states: {
    idle: {
      on: {
        INITIALIZE: {
          target: 'stopped',
          actions: ['storeBookId', 'resetIndex', 'storeResumeIndex']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    stopped: {
      entry: sendTo('audio', { type: 'STOP' }),
      on: {
        PLAY: [
          {
            guard: 'hasParagraphs',
            target: 'loading'
          },
          {
            // Empty paragraphs means we lost them from a failed nav or
            // initial load. Re-publish from the view actor rather than
            // asking for a new page.
            target: 'republishingParagraphs'
          }
        ],
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: 'advanceIndex'
          },
          {
            guard: 'hasParagraphs',
            target: 'waitingForParagraphs',
            actions: 'setDirectionForward'
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: 'setDirectionBackward'
          },
          {
            guard: 'hasParagraphs',
            target: 'loading',
            actions: 'retreatIndex'
          }
        ],
        PARAGRAPHS_UPDATED: [
          // wasTimedOut wins to preserve existing recovery behavior
          {
            guard: 'wasTimedOut',
            target: 'loading',
            actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
          },
          {
            guard: 'hasUnresolvedResume',
            actions: ['storeParagraphs', 'applyResumeIndex']
          },
          {
            actions: ['storeParagraphs']
          }
        ],
        NEXT_PARAGRAPHS_UPDATED: {
          actions: ['storeNextParagraphs']
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: ['storePrevParagraphs']
        },
        // External page navigation while we're already silent. Transition to
        // pageNavigating — the existing state designed for "external nav in
        // flight, wait for paragraphs". Going there directly avoids the
        // spurious NAVIGATE_NEXT that would fire from waitingForParagraphs
        // if PLAY arrives mid-nav (the PLAY → !hasParagraphs →
        // waitingForParagraphs path used to clear paragraphs and double-navigate).
        // Paragraphs are NOT cleared here because nothing's playing; when
        // PARAGRAPHS_UPDATED arrives, pageNavigating transitions back to
        // stopped (if no PLAY arrived) or loading (if PLAY did arrive and
        // set wantsAutoResume).
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: ['setNavDirection', 'clearWantsAutoResume']
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    loading: {
      // Entry: silence whatever the previous state was playing immediately, so
      // the user doesn't hear the old paragraph for the ~50-300 ms TTS fetch
      // window. Idempotent — STOP on already-stopped audio is a no-op.
      entry: sendTo('audio', { type: 'STOP' }),
      after: {
        60000: {
          target: 'error',
          actions: ['logLoadingTimeout', 'flagTimedOut']
        }
      },
      invoke: {
        // The TTS fetch. xstate cancels this promise when `loading` exits —
        // replacing the bridge's manual fetchGeneration counter.
        src: 'fetchTtsLogic',
        input: ({ context }): TtsFetchInput => {
          // `as | undefined` (not a plain annotation) so ts-eslint sees the
          // widened type at use sites — paragraphIndex may point past the end
          // of currentParagraphs while paragraphs are being swapped in/out
          // (transient between PAGE_NAVIGATING and PARAGRAPHS_UPDATED), and
          // the repo doesn't have noUncheckedIndexedAccess on.
          const paragraph = context.currentParagraphs[context.paragraphIndex] as
            | ParagraphWithIndex
            | undefined
          const useOverride =
            context.partialFirstText !== null &&
            context.partialFirstParagraphIndex === context.paragraphIndex
          // Non-null assertions are safe inside the useOverride branch — the
          // guard above proves partialFirstText/Key are non-null.
          const text = useOverride ? context.partialFirstText! : (paragraph?.text ?? '')
          const cfiRange = useOverride ? context.partialFirstKey! : (paragraph?.index ?? '')
          const skip = !paragraph || context.currentParagraphs.length === 0 || !text.trim()
          return {
            bookId: context.bookId,
            cfiRange,
            text,
            skip,
            fetcher: context.fetcher
          }
        },
        onDone: [
          {
            // Skip path (empty/image-only paragraph): treat as if playback
            // ended naturally — let the AUDIO_ENDED handlers below auto-advance
            // or hand off to waitingForParagraphs. Sending via raise would also
            // work; the parent's on-handlers see it identically.
            guard: ({ event }) => event.output.kind === 'skip',
            actions: raise({ type: 'AUDIO_ENDED' })
          },
          {
            // Happy path: ask audioActor to play the freshly-fetched blob.
            // The AUDIO_LOADED reply transitions loading → playing below.
            actions: sendTo('audio', ({ event }) => ({
              type: 'PLAY',
              src: (event.output as { kind: 'play'; src: string }).src
            }))
          }
        ],
        onError: [
          {
            guard: 'hasRetries',
            target: 'loading',
            reenter: true,
            actions: ['incrementRetry', 'logErrorFromInvoke']
          },
          {
            target: 'error',
            actions: ['logErrorFromInvoke', 'clearPartialFirst']
          }
        ]
      },
      on: {
        AUDIO_LOADED: {
          target: 'playing',
          actions: 'clearErrors'
        },
        AUDIO_ERROR: [
          {
            guard: 'hasRetries',
            target: 'loading',
            actions: ['incrementRetry', 'logError'],
            reenter: true
          },
          {
            target: 'error',
            actions: ['logError', 'clearPartialFirst']
          }
        ],
        // Mirror playing's AUDIO_ENDED so the skip path advances cleanly:
        //   - more paragraphs on this page → next loading
        //   - last paragraph → waitingForParagraphs
        AUDIO_ENDED: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: ['clearPartialFirstIfConsumed', 'advanceIndex'],
            reenter: true
          },
          {
            target: 'waitingForParagraphs',
            actions: ['clearPartialFirstIfConsumed', 'setDirectionForward', 'setWantsAutoResume']
          }
        ],
        PAUSE: {
          target: 'paused'
        },
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'resetIndexByDirection'],
          reenter: true
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        CLEANUP: {
          target: 'idle',
          actions: 'resetAll'
        },
        // Page nav started while we're mid-fetch: cancel any in-flight load
        // by transitioning to pageNavigating. We remember we wanted to play
        // so PARAGRAPHS_UPDATED auto-resumes loading on the new page.
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'setWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent'],
          reenter: true
        },
        CHAT_STARTED: {
          target: 'paused.clean',
          actions: ['setWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    playing: {
      on: {
        PAUSE: {
          target: 'paused'
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        // Reaching waitingForParagraphs from playing means the user was
        // actively listening — set wantsAutoResume so once the view actor
        // delivers the new page's paragraphs (via VIEW_CHANGED →
        // PARAGRAPHS_UPDATED), playback continues automatically instead
        // of dropping into `stopped`.
        AUDIO_ENDED: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            // clearPartialFirstIfConsumed MUST run before advanceIndex so it
            // compares against the pre-advance paragraphIndex (the paragraph
            // that just finished playing).
            actions: ['clearPartialFirstIfConsumed', 'advanceIndex']
          },
          {
            target: 'waitingForParagraphs',
            actions: ['clearPartialFirstIfConsumed', 'setDirectionForward', 'setWantsAutoResume']
          }
        ],
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: 'advanceIndex'
          },
          {
            target: 'waitingForParagraphs',
            actions: ['setDirectionForward', 'setWantsAutoResume']
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: ['setDirectionBackward', 'setWantsAutoResume']
          },
          {
            target: 'loading',
            actions: 'retreatIndex'
          }
        ],
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'resetIndexByDirection']
        },
        NEXT_PARAGRAPHS_UPDATED: {
          actions: 'storeNextParagraphs'
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: 'storePrevParagraphs'
        },
        AUDIO_ERROR: {
          target: 'error',
          actions: 'logError'
        },
        // External page nav started during playback. Stop audio (handled by
        // the entry side-effect on pageNavigating) and auto-resume on the
        // new page when PARAGRAPHS_UPDATED arrives.
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'setWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        },
        REPEAT: {
          target: 'loading',
          reenter: true,
          actions: 'clearPartialFirst'
        },
        CHAT_STARTED: {
          target: 'paused.clean',
          actions: ['setWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    paused: {
      initial: 'clean',
      entry: sendTo('audio', { type: 'PAUSE' }),
      on: {
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: 'advanceIndex'
          },
          {
            target: 'waitingForParagraphs',
            actions: 'setDirectionForward'
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: 'setDirectionBackward'
          },
          {
            target: 'loading',
            actions: 'retreatIndex'
          }
        ],
        NEXT_PARAGRAPHS_UPDATED: {
          actions: 'storeNextParagraphs'
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: 'storePrevParagraphs'
        },
        // External page nav while paused: jump to the new page but stay
        // effectively-paused (no auto-resume — user paused intentionally).
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'clearWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        // Chat opened while user is already paused. They paused intentionally,
        // so DO NOT set wantsAutoResumeAfterChat — user remains paused after
        // chat ends. Just clear any partialFirst override on this paragraph.
        CHAT_STARTED: {
          actions: ['clearPartialFirst']
        }
      },
      states: {
        clean: {
          // wantsAutoResumeAfterChat is meaningful only while we're paused
          // because of a chat interruption. If the user takes any action that
          // leaves paused.clean (RESUME via keyboard shortcut, NEXT/PREV,
          // PARAGRAPHS_UPDATED from a page curl, etc.), that intent supersedes
          // the auto-resume. Clearing here makes the later CHAT_ENDED a no-op.
          exit: ['clearWantsAutoResumeAfterChat'],
          on: {
            RESUME: {
              target: '#player.playing',
              // From paused.clean, currentParagraphs are unchanged and the
              // audio element still has the right src loaded — just resume.
              actions: sendTo('audio', { type: 'RESUME' })
            },
            PARAGRAPHS_UPDATED: {
              target: 'stale',
              actions: ['storeParagraphs', 'resetIndexByDirection']
            },
            PLAY_FROM: {
              target: '#player.loading',
              actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
            }
          }
        },
        stale: {
          on: {
            RESUME: {
              target: '#player.loading'
            },
            PARAGRAPHS_UPDATED: {
              target: 'stale',
              actions: ['storeParagraphs', 'resetIndexByDirection'],
              reenter: true
            },
            PLAY_FROM: {
              target: '#player.loading',
              actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
            }
          }
        }
      }
    },

    waitingForParagraphs: {
      // Stop the previous audio AND ask the view actor to navigate. The
      // view actor will emit VIEW_CHANGED (re-raised as PARAGRAPHS_UPDATED)
      // or NAV_NO_PROGRESS, both already handled below.
      entry: [
        sendTo('audio', { type: 'STOP' }),
        sendTo('view', ({ context }) => ({
          type:
            context.direction === 'backward'
              ? ('NAVIGATE_PREV' as const)
              : ('NAVIGATE_NEXT' as const)
        }))
      ],
      after: {
        10000: {
          target: 'stopped',
          actions: 'flagTimedOut'
        }
      },
      on: {
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
        },
        // The view-layer (orchestration bridge or, post-Phase-3.4, the
        // view actor) detected end-of-document / no-relocation. Don't loop;
        // stop. This is the structural fix for the auto-advance-past-last-
        // paragraph snap-back bug.
        NAV_NO_PROGRESS: {
          target: 'stopped',
          actions: ['resetIndex', 'clearWantsAutoResume', 'clearPartialFirst']
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          // Preserve wantsAutoResume AND direction from however we got here.
          // The player set the direction (forward/backward) on entry to
          // waitingForParagraphs based on the user's NEXT/PREV intent; the
          // event's direction field is best-effort (the publisher can't
          // always tell which way the format reader is going) and must not
          // overwrite the player's authoritative intent. Specifically,
          // after PREV at the first paragraph the player needs
          // direction='backward' to survive so resetIndexByDirection lands
          // on the LAST paragraph of the previous page rather than the first.
          actions: ['clearCurrentParagraphs', 'clearPartialFirst']
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        },
        CHAT_STARTED: {
          target: '#player.paused.clean',
          actions: ['setWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    republishingParagraphs: {
      // Entered when the machine is in `stopped` with empty currentParagraphs
      // and the user clicks PLAY. Paragraphs were lost (typically via
      // clearCurrentParagraphs during a failed/timed-out page navigation).
      // The entry action sends REPUBLISH to the view actor, which re-reads
      // its current view and emits VIEW_CHANGED (re-raised as
      // PARAGRAPHS_UPDATED) — or NAV_NO_PROGRESS if the view is empty.
      // Unlike waitingForParagraphs, this state does NOT request a new page
      // navigation — the player has not asked to advance.
      // PLAY_FROM is intentionally NOT handled here — the paragraphs are not
      // yet known so a targeted jump cannot be validated.
      entry: [
        sendTo('audio', { type: 'STOP' }),
        // Ask the view actor to re-emit the current view's paragraphs.
        // The actor validates non-emptiness and emits VIEW_CHANGED
        // (re-raised as PARAGRAPHS_UPDATED) or NAV_NO_PROGRESS.
        sendTo('view', { type: 'REPUBLISH' })
      ],
      after: {
        10000: {
          target: 'stopped',
          actions: 'flagTimedOut'
        }
      },
      on: {
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
        },
        // republish bailed (same view / image-only). Stop instead of timing
        // out at 10 s.
        NAV_NO_PROGRESS: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: ['setNavDirection', 'clearCurrentParagraphs', 'clearPartialFirst']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    // Distinct from waitingForParagraphs:
    //   - waitingForParagraphs is entered when the *player itself* wants the
    //     next/prev page (via player NEXT/PREV / AUDIO_ENDED on last
    //     paragraph). Its entry sends NAVIGATE_NEXT/PREV to the view actor.
    //   - pageNavigating is entered when an *external* navigation has
    //     already started (user gesture — epub page-curl, PDF scroll past a
    //     boundary, etc.). The format reader is already mid-transition;
    //     sending another NAVIGATE_NEXT here would double-navigate. So this
    //     state just waits for PARAGRAPHS_UPDATED and resumes loading IFF
    //     the player was active before.
    pageNavigating: {
      entry: sendTo('audio', { type: 'STOP' }),
      after: {
        10000: {
          target: 'stopped',
          actions: 'flagTimedOut'
        }
      },
      on: {
        PARAGRAPHS_UPDATED: [
          {
            guard: ({ context }) => context.wantsAutoResume,
            target: 'loading',
            actions: [
              'storeParagraphs',
              'clearTimedOut',
              'resetIndexByDirection',
              'clearWantsAutoResume'
            ]
          },
          {
            target: 'stopped',
            actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
          }
        ],
        // THE bug fix. When the external nav settles but the format reader
        // didn't actually advance — end of document, drift restore, image-
        // only page — the view actor sends NAV_NO_PROGRESS instead of
        // re-emitting the same view's paragraphs. Without this, the old
        // bridge re-published, driving PARAGRAPHS_UPDATED → loading →
        // paragraph 0 of the OLD view, which users perceived as "looping
        // back".
        NAV_NO_PROGRESS: {
          target: 'stopped',
          actions: ['resetIndex', 'clearWantsAutoResume', 'clearPartialFirst']
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearWantsAutoResume', 'clearPartialFirst']
        },
        PLAY: {
          // User clicked Play during a page-curl. Remember they want to play
          // and wait for the new paragraphs to land before starting.
          actions: 'setWantsAutoResume'
        },
        PAUSE: {
          actions: 'clearWantsAutoResume'
        },
        PAGE_NAVIGATING: {
          // A second nav (rapid Next clicks). Stay here; refresh direction.
          actions: 'setNavDirection'
        },
        NEXT_PARAGRAPHS_UPDATED: {
          actions: 'storeNextParagraphs'
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: 'storePrevParagraphs'
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    error: {
      on: {
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: ['advanceIndex', 'clearErrors']
          },
          {
            target: 'waitingForParagraphs',
            actions: ['setDirectionForward', 'clearErrors']
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: ['setDirectionBackward', 'clearErrors']
          },
          {
            target: 'loading',
            actions: ['retreatIndex', 'clearErrors']
          }
        ],
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearErrors', 'clearPartialFirst']
        },
        PLAY: {
          target: 'loading',
          actions: ['clearErrors', 'resetIndex']
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'clearErrors',
            'clearWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['clearErrors', 'setPartialFirst', 'setParagraphIndexFromEvent']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    }
  }
})
