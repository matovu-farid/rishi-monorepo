import { create } from "zustand";
import { devtools } from "zustand/middleware";

const TOUR_COMPLETED_KEY = "rishi:tour-completed";
const HINTS_SEEN_KEY = "rishi:hints-seen";

export interface TourStep {
  target: string;
  title: string;
  description: string;
  descriptionEmpty?: string;
  position: "above" | "below" | "left" | "right";
  routePrefix?: string;
}

export const TOUR_STEPS: TourStep[] = [
  { target: "import-books", title: "Add Your Books", description: "Drag & drop files here, or use these buttons to add books from your device.", position: "below" },
  { target: "book-grid", title: "Your Library", description: "Click any book to start reading. Right-click for more options.", descriptionEmpty: "Your books will appear here once imported.", position: "above" },
  { target: "reader-toolbar", title: "Reader Controls", description: "Access settings, bookmarks, table of contents, and more from the toolbar.", position: "below", routePrefix: "/books" },
  { target: "ai-chat", title: "Chat With Your Book", description: "Ask questions about what you're reading. AI will answer using the book's content.", position: "left", routePrefix: "/books" },
];

interface TutorialState {
  tourActive: boolean;
  tourStep: number;
  tourCompleted: boolean;
  tourPaused: boolean;
  hintsShown: Record<string, boolean>;
  startTour: () => void;
  nextStep: () => void;
  skipTour: () => void;
  completeTour: () => void;
  pauseTour: () => void;
  resumeTour: () => void;
  resetTour: () => void;
  dismissHint: (hintId: string) => void;
  isHintSeen: (hintId: string) => boolean;
}

function readHintsShown(): Record<string, boolean> {
  try { const raw = localStorage.getItem(HINTS_SEEN_KEY); return raw ? JSON.parse(raw) : {}; } catch { return {}; }
}

export const useTutorialStore = create<TutorialState>()(
  devtools(
    (set, get) => ({
      tourActive: false,
      tourStep: 0,
      tourCompleted: localStorage.getItem(TOUR_COMPLETED_KEY) === "1",
      tourPaused: false,
      hintsShown: readHintsShown(),
      startTour: () => { if (get().tourCompleted) return; set({ tourActive: true, tourStep: 0, tourPaused: false }); },
      nextStep: () => {
        const { tourStep } = get();
        const next = tourStep + 1;
        if (next >= TOUR_STEPS.length) { get().completeTour(); }
        else {
          const nextDef = TOUR_STEPS[next];
          const currDef = TOUR_STEPS[tourStep];
          set(nextDef.routePrefix && !currDef.routePrefix ? { tourStep: next, tourPaused: true } : { tourStep: next });
        }
      },
      skipTour: () => { set({ tourActive: false, tourStep: 0, tourPaused: false, tourCompleted: true }); localStorage.setItem(TOUR_COMPLETED_KEY, "1"); },
      completeTour: () => { set({ tourActive: false, tourStep: 0, tourPaused: false, tourCompleted: true }); localStorage.setItem(TOUR_COMPLETED_KEY, "1"); },
      pauseTour: () => set({ tourPaused: true }),
      resumeTour: () => set({ tourPaused: false }),
      resetTour: () => { set({ tourCompleted: false, tourStep: 0, tourPaused: false, tourActive: false, hintsShown: {} }); localStorage.removeItem(TOUR_COMPLETED_KEY); localStorage.removeItem(HINTS_SEEN_KEY); },
      dismissHint: (id) => { const updated = { ...get().hintsShown, [id]: true }; set({ hintsShown: updated }); localStorage.setItem(HINTS_SEEN_KEY, JSON.stringify(updated)); },
      isHintSeen: (id) => !!get().hintsShown[id],
    }),
    { name: "tutorial-store" }
  )
);
