/**
 * Mobile tutorialStore — ported verbatim from
 * `apps/rishi-electron/src/renderer/src/stores/tutorialStore.ts`.
 *
 * Only difference from electron: persistence swaps `localStorage` for the
 * MMKV-backed `createStorage(...)` shim. The tour-step structure and the
 * public action surface are unchanged.
 *
 * Tour UI itself is not in this batch — see Gap G28 follow-up.
 */
import { create } from 'zustand'
import { createStorage } from '@/lib/storage/mmkv'

const bucket = createStorage('rishi.mobile.tutorial')

const TOUR_COMPLETED_KEY = 'tour-completed'
const HINTS_SEEN_KEY = 'hints-seen'

export interface TourStep {
  target: string
  title: string
  description: string
  descriptionEmpty?: string
  position: 'above' | 'below' | 'left' | 'right'
  routePrefix?: string
}

export const TOUR_STEPS: TourStep[] = [
  {
    target: 'import-books',
    title: 'Add Your Books',
    description:
      'Tap here to add books from your device, iCloud, or a URL.',
    position: 'below',
  },
  {
    target: 'book-grid',
    title: 'Your Library',
    description: 'Tap any book to start reading. Long-press for more options.',
    descriptionEmpty: 'Your books will appear here once imported.',
    position: 'above',
  },
  {
    target: 'ai-chat',
    title: 'Chat With Your Book',
    description:
      "Ask questions about what you're reading. AI will answer using the book's content.",
    position: 'left',
    routePrefix: '/books',
  },
]

interface TutorialState {
  tourActive: boolean
  tourStep: number
  tourCompleted: boolean
  tourPaused: boolean
  hintsShown: Record<string, boolean>

  startTour: () => void
  nextStep: () => void
  skipTour: () => void
  completeTour: () => void
  pauseTour: () => void
  resumeTour: () => void
  resetTour: () => void
  dismissHint: (hintId: string) => void
  isHintSeen: (hintId: string) => boolean
}

function readHintsShown(): Record<string, boolean> {
  try {
    const raw = bucket.getItem(HINTS_SEEN_KEY)
    return raw ? (JSON.parse(raw) as Record<string, boolean>) : {}
  } catch {
    return {}
  }
}

function persistHintsShown(hints: Record<string, boolean>): void {
  try {
    bucket.setItem(HINTS_SEEN_KEY, JSON.stringify(hints))
  } catch (err) {
    console.warn('[tutorialStore] failed to persist hints-seen:', err)
  }
}

function persistTourCompleted(completed: boolean): void {
  try {
    if (completed) {
      bucket.setItem(TOUR_COMPLETED_KEY, '1')
    } else {
      bucket.removeItem(TOUR_COMPLETED_KEY)
    }
  } catch (err) {
    console.warn('[tutorialStore] failed to persist tour-completed:', err)
  }
}

export const useTutorialStore = create<TutorialState>()((set, get) => ({
  tourActive: false,
  tourStep: 0,
  tourCompleted: bucket.getItem(TOUR_COMPLETED_KEY) === '1',
  tourPaused: false,
  hintsShown: readHintsShown(),

  startTour: () => {
    if (get().tourCompleted) return
    set({ tourActive: true, tourStep: 0, tourPaused: false })
  },

  nextStep: () => {
    const { tourStep } = get()
    const nextIndex = tourStep + 1
    if (nextIndex >= TOUR_STEPS.length) {
      get().completeTour()
    } else {
      const nextStepDef = TOUR_STEPS[nextIndex]
      const currentStep = TOUR_STEPS[tourStep]
      if (nextStepDef.routePrefix && !currentStep.routePrefix) {
        set({ tourStep: nextIndex, tourPaused: true })
      } else {
        set({ tourStep: nextIndex })
      }
    }
  },

  skipTour: () => {
    set({ tourActive: false, tourStep: 0, tourPaused: false, tourCompleted: true })
    persistTourCompleted(true)
  },

  completeTour: () => {
    set({ tourActive: false, tourStep: 0, tourPaused: false, tourCompleted: true })
    persistTourCompleted(true)
  },

  pauseTour: () => set({ tourPaused: true }),
  resumeTour: () => set({ tourPaused: false }),

  resetTour: () => {
    set({
      tourCompleted: false,
      tourStep: 0,
      tourPaused: false,
      tourActive: false,
      hintsShown: {},
    })
    persistTourCompleted(false)
    try {
      bucket.removeItem(HINTS_SEEN_KEY)
    } catch {
      // no-op
    }
  },

  dismissHint: (hintId: string) => {
    const updated = { ...get().hintsShown, [hintId]: true }
    set({ hintsShown: updated })
    persistHintsShown(updated)
  },

  isHintSeen: (hintId: string) => !!get().hintsShown[hintId],
}))
