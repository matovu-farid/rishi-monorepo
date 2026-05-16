import { create } from 'zustand'

export type EpubSelection = {
  format: 'epub'
  cfiRange: string
  text: string
}

// Future formats (PDF/AZW3/MOBI) will add discriminated variants here.
export type ReaderSelection = EpubSelection

interface SelectionStore {
  current: ReaderSelection | null
  setEpubSelection: (sel: { cfiRange: string; text: string }) => void
  clear: () => void
}

export const useSelectionStore = create<SelectionStore>((set) => ({
  current: null,
  setEpubSelection: (sel) => set({ current: { format: 'epub', ...sel } }),
  clear: () => set({ current: null })
}))
