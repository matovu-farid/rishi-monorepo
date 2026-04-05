export interface Book {
  id: string // UUID generated at import time
  title: string
  author: string
  coverPath: string | null // Local file path to extracted cover image
  filePath: string // Local file path to the EPUB file in app documents
  format: 'epub' // Only EPUB in this phase; 'pdf' added in Phase 3
  currentCfi: string | null // ePubCFI string for reading position
  createdAt: number // Unix timestamp ms
}

export type ThemeName = 'white' | 'dark' | 'yellow'

export interface ReaderTheme {
  name: ThemeName
  label: string // Display label: "Light", "Dark", "Sepia"
  background: string // CSS color for epub.js changeTheme
  color: string // CSS text color for epub.js changeTheme
  toolbarBg: string // Background for native toolbar overlay
  toolbarText: string // Text color for native toolbar
  swatchColor: string // Color shown in theme picker swatch
  swatchBorder: string // Border color for swatch (visible on white backgrounds)
}

export interface ReaderSettings {
  themeName: ThemeName
  fontSize: number // Percentage: 80, 90, 100, 110, 120, 130, 140, 150
  fontFamily: 'serif' | 'sans-serif'
}

export const DEFAULT_READER_SETTINGS: ReaderSettings = {
  themeName: 'white',
  fontSize: 100,
  fontFamily: 'serif',
}
