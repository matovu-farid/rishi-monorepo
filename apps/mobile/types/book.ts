export interface Book {
  id: string // UUID generated at import time
  title: string
  author: string
  coverPath: string | null // Local file path to extracted cover image
  filePath: string // Local file path to the book file in app documents
  format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'
  currentCfi: string | null // ePubCFI string for EPUB reading position
  currentPage: number | null // Page number for PDF reading position
  /**
   * #41 — Persisted format-honest progress, a 0..1 float, used to render
   * the "Reading Now" pill subline on the library tab AFTER the reader
   * has been closed. EPUB sources this from epubjs's onRelocated progress
   * arg; PDF/DJVU compute `currentPage / total`; MOBI/AZW3 compute
   * `currentChapter / chapterCount`. `null` for legacy rows that haven't
   * been opened post-migration — the pill omits the subline in that case
   * rather than showing a stale or "0%" label.
   */
  lastProgressPercent: number | null
  createdAt: number // Unix timestamp ms
  /**
   * P1-AC: true when cover extraction was attempted at import time and
   * failed. Derived in `lib/book-storage.mapRowToBook` from the
   * `coverPath = '__failed'` sentinel persisted by the CoverPort.
   * The library UI uses this to offer a "Retry cover extraction"
   * long-press affordance instead of a silent letter-tile fallback.
   */
  coverExtractionFailed?: boolean
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
