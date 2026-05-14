import { create } from 'zustand'
import { devtools } from 'zustand/middleware'

const TOUR_COMPLETED_KEY = 'rishi:tour-completed'
const HINTS_SEEN_KEY = 'rishi:hints-seen'

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
    description: 'Drag & drop files here, or use these buttons to add books from your device.',
    position: 'below'
  },
  {
    target: 'book-grid',
    title: 'Your Library',
    description: 'Click any book to start reading. Right-click for more options.',
    descriptionEmpty: 'Your books will appear here once imported.',
    position: 'above'
  },
  {
    target: 'ai-chat',
    title: 'Chat With Your Book',
    description:
      "Ask questions about what you're reading. AI will answer using the book's content.",
    position: 'left',
    routePrefix: '/books'
  }
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
    if (typeof localStorage === 'undefined') return {}
    const raw = localStorage.getItem(HINTS_SEEN_KEY)
    return raw ? JSON.parse(raw) : {}
  } catch {
    return {}
  }
}

function persistHintsShown(hints: Record<string, boolean>) {
  try {
    if (typeof localStorage === 'undefined') return
    localStorage.setItem(HINTS_SEEN_KEY, JSON.stringify(hints))
  } catch (err) {
    console.warn('[tutorialStore] failed to persist hints-seen:', err)
  }
}

function persistTourCompleted(completed: boolean) {
  try {
    if (typeof localStorage === 'undefined') return
    if (completed) {
      localStorage.setItem(TOUR_COMPLETED_KEY, '1')
    } else {
      localStorage.removeItem(TOUR_COMPLETED_KEY)
    }
  } catch (err) {
    console.warn('[tutorialStore] failed to persist tour-completed:', err)
  }
}

export const useTutorialStore = create<TutorialState>()(
  devtools(
    (set, get) => ({
      tourActive: false,
      tourStep: 0,
      tourCompleted:
        typeof localStorage !== 'undefined'
          ? localStorage.getItem(TOUR_COMPLETED_KEY) === '1'
          : false,
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
          hintsShown: {}
        })
        persistTourCompleted(false)
        try {
          if (typeof localStorage !== 'undefined') localStorage.removeItem(HINTS_SEEN_KEY)
        } catch {
          // no-op
        }
      },

      dismissHint: (hintId: string) => {
        const updated = { ...get().hintsShown, [hintId]: true }
        set({ hintsShown: updated })
        persistHintsShown(updated)
      },

      isHintSeen: (hintId: string) => !!get().hintsShown[hintId]
    }),
    { name: 'tutorial-store' }
  )
)
