// Format parity contract for the view-actor protocol (viewActor.ts).
//
// Both pdfViewActor (used by PDF/MOBI/AZW3) and epubViewActor MUST satisfy
// the same ViewActorCommand → ViewActorEmit contract. This file runs the
// shared scenarios against each actor through a format-specific adapter so
// a future divergence (a new format that handles NAVIGATE_NEXT differently,
// or omits a NAV_NO_PROGRESS branch) fails here instead of at runtime.
//
// Per-actor edge cases (PDF seed-on-mount, EPUB bounce-back window, etc.)
// stay in their own *.test.ts files. This file only encodes invariants that
// must hold for every format.

import { describe, it, expect, vi } from 'vitest'
import { createActor, createMachine, type ActorRefFrom } from 'xstate'
import { pdfViewActor, type PdfViewInput } from '../pdfViewActor'
import { epubViewActor, type EpubViewInput } from '../epubViewActor'
import type { ViewActorCommand, ViewActorEmit } from '../viewActor'
import type { ParagraphWithIndex } from '@/stores/playerStore'

const P = (id: string, text = 'lorem'): ParagraphWithIndex => ({ index: id, text })

async function flush(): Promise<void> {
  await new Promise<void>((r) => setTimeout(r, 0))
}

/**
 * A format-agnostic harness that exposes only what parity scenarios need:
 * send a command, simulate the view settling at a locator, simulate a stuck
 * navigation, and read the emit log.
 */
interface ParityHarness {
  send(cmd: ViewActorCommand): void
  /** Simulate the view settling at `locator` with `paragraphs` ready. */
  settleAt(locator: string, paragraphs: ParagraphWithIndex[]): Promise<void>
  /**
   * Put the harness in a state where the next NAVIGATE_* command will not
   * make progress (document boundary). PDF: next/prev/goTo return false.
   * EPUB: rendition.next/prev/display throw.
   */
  setAtBoundary(): void
  captured: ViewActorEmit[]
  stop(): void
}

// ─── PDF adapter ──────────────────────────────────────────────────────────

type PdfSnapshot = { page: number; paragraphs: ParagraphWithIndex[]; dataReady: boolean }

class FakePdfControls {
  page = 0
  paragraphs: ParagraphWithIndex[] = []
  dataReady = true
  nextWillNavigate = true
  prevWillNavigate = true
  goToWillNavigate = true
  private subs: Array<(s: PdfSnapshot) => void> = []
  next = vi.fn((): boolean => this.nextWillNavigate)
  prev = vi.fn((): boolean => this.prevWillNavigate)
  goTo = vi.fn((_: number): boolean => this.goToWillNavigate)
  subscribe = (cb: (s: PdfSnapshot) => void): (() => void) => {
    this.subs.push(cb)
    return () => {
      this.subs = this.subs.filter((s) => s !== cb)
    }
  }
  getSnapshot = (): PdfSnapshot => ({
    page: this.page,
    paragraphs: this.paragraphs,
    dataReady: this.dataReady
  })
  emit(page: number, paragraphs: ParagraphWithIndex[]): void {
    this.page = page
    this.paragraphs = paragraphs
    this.dataReady = true
    this.subs.forEach((s) => s(this.getSnapshot()))
  }
}

function makePdfHarness(initial: {
  locator: string
  paragraphs: ParagraphWithIndex[]
}): ParityHarness {
  const controls = new FakePdfControls()
  controls.page = Number(initial.locator)
  controls.paragraphs = initial.paragraphs
  const captured: ViewActorEmit[] = []
  const parentMachine = createMachine({
    types: {} as { events: ViewActorEmit },
    invoke: {
      id: 'view',
      src: pdfViewActor,
      input: {
        next: controls.next,
        prev: controls.prev,
        goTo: controls.goTo,
        subscribe: controls.subscribe,
        getSnapshot: controls.getSnapshot
      } satisfies PdfViewInput
    },
    on: {
      VIEW_CHANGED: { actions: ({ event }) => captured.push(event as ViewActorEmit) },
      NAV_NO_PROGRESS: { actions: ({ event }) => captured.push(event as ViewActorEmit) }
    }
  })
  const parent = createActor(parentMachine)
  parent.start()
  const actorRef = parent.getSnapshot().children.view as ActorRefFrom<typeof pdfViewActor>

  return {
    send: (cmd) => actorRef.send(cmd),
    settleAt: async (locator, paragraphs) => {
      controls.emit(Number(locator), paragraphs)
      await flush()
    },
    setAtBoundary: () => {
      controls.nextWillNavigate = false
      controls.prevWillNavigate = false
      controls.goToWillNavigate = false
    },
    captured,
    stop: () => parent.stop()
  }
}

// ─── EPUB adapter ─────────────────────────────────────────────────────────

type RelocatedListener = (location: { start: { cfi: string } }) => void

class FakeRendition {
  location: { start: { cfi: string } } | null = null
  private listeners: Record<string, RelocatedListener[]> = {}
  next = vi.fn(async (): Promise<void> => {})
  prev = vi.fn(async (): Promise<void> => {})
  display = vi.fn(async (_: string): Promise<void> => {})
  on(event: string, listener: RelocatedListener): void {
    if (!this.listeners[event]) this.listeners[event] = []
    this.listeners[event].push(listener)
  }
  off(event: string, listener: RelocatedListener): void {
    this.listeners[event] = (this.listeners[event] ?? []).filter((l) => l !== listener)
  }
  emit(event: string, payload: { start: { cfi: string } }): void {
    ;(this.listeners[event] ?? []).forEach((l) => l(payload))
  }
}

function makeEpubHarness(initial: {
  locator: string
  paragraphs: ParagraphWithIndex[]
}): ParityHarness {
  const rendition = new FakeRendition()
  rendition.location = { start: { cfi: initial.locator } }
  let currentParagraphs: ParagraphWithIndex[] = initial.paragraphs
  const captured: ViewActorEmit[] = []
  const parentMachine = createMachine({
    types: {} as { events: ViewActorEmit },
    invoke: {
      id: 'view',
      src: epubViewActor,
      input: {
        rendition: rendition as unknown as EpubViewInput['rendition'],
        getParagraphs: () => currentParagraphs
      } satisfies EpubViewInput
    },
    on: {
      VIEW_CHANGED: { actions: ({ event }) => captured.push(event as ViewActorEmit) },
      NAV_NO_PROGRESS: { actions: ({ event }) => captured.push(event as ViewActorEmit) }
    }
  })
  const parent = createActor(parentMachine)
  parent.start()
  const actorRef = parent.getSnapshot().children.view as ActorRefFrom<typeof epubViewActor>

  return {
    send: (cmd) => actorRef.send(cmd),
    settleAt: async (locator, paragraphs) => {
      currentParagraphs = paragraphs
      rendition.emit('relocated', { start: { cfi: locator } })
      await flush()
    },
    setAtBoundary: () => {
      const boundary = new Error('No Section Found')
      rendition.next = vi.fn(async () => {
        throw boundary
      })
      rendition.prev = vi.fn(async () => {
        throw boundary
      })
      rendition.display = vi.fn(async () => {
        throw boundary
      })
    },
    captured,
    stop: () => parent.stop()
  }
}

// ─── Parameterized contract ───────────────────────────────────────────────

interface FormatCase {
  name: 'pdf' | 'epub'
  /** locator after a successful "next" nav. */
  nextLocator: string
  /** locator after a successful "prev" nav. */
  prevLocator: string
  /** locator used by NAVIGATE_TO. */
  jumpLocator: string
  /** Build a harness with the actor already mounted at `initial`. */
  makeHarness(initial: { locator: string; paragraphs: ParagraphWithIndex[] }): ParityHarness
}

const FORMATS: FormatCase[] = [
  {
    name: 'pdf',
    nextLocator: '2',
    prevLocator: '0',
    jumpLocator: '7',
    makeHarness: makePdfHarness
  },
  {
    name: 'epub',
    nextLocator: 'cfi:after',
    prevLocator: 'cfi:before',
    jumpLocator: 'cfi:bookmark',
    makeHarness: makeEpubHarness
  }
]

describe('viewActor — format parity contract', () => {
  for (const fmt of FORMATS) {
    describe(`[${fmt.name}]`, () => {
      const start = { locator: fmt.name === 'pdf' ? '1' : 'cfi:start', paragraphs: [P('seed')] }

      it('NAVIGATE_NEXT settling at a new locator emits VIEW_CHANGED with the new locator and paragraphs', async () => {
        const h = fmt.makeHarness(start)
        try {
          h.captured.length = 0 // drop any seed-on-mount emit
          h.send({ type: 'NAVIGATE_NEXT' })
          await flush()
          await h.settleAt(fmt.nextLocator, [P(`${fmt.nextLocator}-0`), P(`${fmt.nextLocator}-1`)])
          expect(h.captured).toEqual([
            {
              type: 'VIEW_CHANGED',
              locator: fmt.nextLocator,
              paragraphs: [P(`${fmt.nextLocator}-0`), P(`${fmt.nextLocator}-1`)]
            }
          ])
        } finally {
          h.stop()
        }
      })

      it('NAVIGATE_PREV settling at a new locator emits VIEW_CHANGED with the new locator and paragraphs', async () => {
        const h = fmt.makeHarness(start)
        try {
          h.captured.length = 0
          h.send({ type: 'NAVIGATE_PREV' })
          await flush()
          await h.settleAt(fmt.prevLocator, [P(`${fmt.prevLocator}-0`)])
          expect(h.captured).toEqual([
            {
              type: 'VIEW_CHANGED',
              locator: fmt.prevLocator,
              paragraphs: [P(`${fmt.prevLocator}-0`)]
            }
          ])
        } finally {
          h.stop()
        }
      })

      it('NAVIGATE_TO settling at the target locator emits VIEW_CHANGED with that locator', async () => {
        const h = fmt.makeHarness(start)
        try {
          h.captured.length = 0
          h.send({ type: 'NAVIGATE_TO', locator: fmt.jumpLocator })
          await flush()
          await h.settleAt(fmt.jumpLocator, [P(`${fmt.jumpLocator}-0`)])
          expect(h.captured).toEqual([
            {
              type: 'VIEW_CHANGED',
              locator: fmt.jumpLocator,
              paragraphs: [P(`${fmt.jumpLocator}-0`)]
            }
          ])
        } finally {
          h.stop()
        }
      })

      it('NAVIGATE_NEXT at end-of-document emits NAV_NO_PROGRESS, never a loop-back VIEW_CHANGED', async () => {
        const h = fmt.makeHarness(start)
        try {
          h.captured.length = 0
          h.setAtBoundary()
          h.send({ type: 'NAVIGATE_NEXT' })
          await flush()
          expect(h.captured.length).toBeGreaterThan(0)
          expect(h.captured[0]).toMatchObject({ type: 'NAV_NO_PROGRESS' })
          const looped = h.captured.find((e) => e.type === 'VIEW_CHANGED')
          expect(looped, `${fmt.name} must not emit a loop-back VIEW_CHANGED`).toBeUndefined()
        } finally {
          h.stop()
        }
      })

      it('nav that settles with empty paragraphs emits NAV_NO_PROGRESS', async () => {
        const h = fmt.makeHarness(start)
        try {
          h.captured.length = 0
          h.send({ type: 'NAVIGATE_NEXT' })
          await flush()
          await h.settleAt(fmt.nextLocator, []) // image-only view
          expect(h.captured).toEqual([{ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }])
        } finally {
          h.stop()
        }
      })
    })
  }
})
